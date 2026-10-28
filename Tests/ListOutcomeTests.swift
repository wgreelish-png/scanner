import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ListOutcomeTests: XCTestCase {
    private enum InjectedFailure: Error { case saveRefused }
    private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let secondDate = Date(timeIntervalSince1970: 1_700_000_600)

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func candidate(_ ref: String, price: Decimal?) -> CardCandidate {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.identity.productID = ref; card.identity.skuID = "123456"
        card.identity.printing = "Holofoil"; card.identity.condition = "Lightly Played"
        card.name = ref; card.marketPrice = price
        return card
    }
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func testNewAndUnmarkedListsAreDifferentFromExplicitNothingHappened() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Unmarked"); context.insert(list); try context.save()
        XCTAssertNil(list.transactionOutcomeData); XCTAssertNil(list.outcomeRecord)
        XCTAssertEqual(list.outcomeTitle, "No status")
        try ListOutcomeService.set(.nothingHappened, for: list, context: context, now: firstDate)
        XCTAssertNotNil(list.transactionOutcomeData)
        XCTAssertEqual(list.outcomeRecord, ListOutcomeRecord(kind: .nothingHappened, recordedAt: firstDate))
        XCTAssertEqual(list.outcomeTitle, "Nothing Happened")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScanSession>()), 0)
    }

    func testOutcomeLabelsAreExplicitAndStable() async {
        XCTAssertEqual(ListOutcomeKind.allCases.map(\.title), ["Purchase", "Trade + Purchase", "Trade", "Nothing Happened"])
        XCTAssertEqual(Set(ListOutcomeKind.allCases.map(\.id)).count, 4)
    }

    func testSameOutcomeAndAlreadyClearAreIdempotentWithoutSavingOtherPendingEdits() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "List"); context.insert(list); try context.save()
        var saves = 0
        try ListOutcomeService.set(nil, for: list, context: context, now: firstDate, save: { _ in saves += 1 })
        XCTAssertEqual(saves, 0)
        try ListOutcomeService.set(.purchase, for: list, context: context, now: firstDate, save: {
            saves += 1; try $0.save()
        })
        let original = list.transactionOutcomeData
        let pending = CardList(name: "Still pending"); context.insert(pending)
        try ListOutcomeService.set(.purchase, for: list, context: context, now: secondDate, save: { _ in saves += 1 })
        XCTAssertEqual(saves, 1); XCTAssertEqual(list.transactionOutcomeData, original)
        XCTAssertEqual(list.outcomeRecord?.recordedAt, firstDate)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CardList>()), 1)
        XCTAssertTrue(context.insertedModelsArray.contains { ($0 as? CardList)?.id == pending.id })
    }

    func testEveryOutcomeSurvivesDiskRelaunchChangesAndClear() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("outcomes.store")
        func create() throws -> UUID {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let list = CardList(name: "Persistent list"); context.insert(list); try context.save(); return list.id
        }
        let id = try create()
        func mark(_ kind: ListOutcomeKind?, date: Date) throws {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first { $0.id == id })
            try ListOutcomeService.set(kind, for: list, context: context, now: date)
        }
        func check(_ kind: ListOutcomeKind?, date: Date?) throws {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first)
            XCTAssertEqual(list.id, id); XCTAssertEqual(list.name, "Persistent list")
            XCTAssertEqual(list.outcomeRecord?.kind, kind); XCTAssertEqual(list.outcomeRecord?.recordedAt, date)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScanSession>()), 0)
            if kind == nil { XCTAssertNil(list.transactionOutcomeData); XCTAssertEqual(list.outcomeTitle, "No status") }
        }
        try check(nil, date: nil)
        for (index, kind) in ListOutcomeKind.allCases.enumerated() {
            let date = firstDate.addingTimeInterval(Double(index) * 10)
            try mark(kind, date: date); try check(kind, date: date)
        }
        try mark(nil, date: secondDate); try check(nil, date: nil)
    }

    func testFailedMarkKeepsPreviousOutcomeAndUnrelatedPendingChangesThenRetryPersists() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Original name"); context.insert(list); try context.save()
        try ListOutcomeService.set(.purchase, for: list, context: context, now: firstDate)
        let previous = list.transactionOutcomeData
        list.name = "Unsaved rename"
        let other = CardList(name: "Pending other list"); context.insert(other)
        let otherID = other.id
        XCTAssertThrowsError(try ListOutcomeService.set(.tradeAndPurchase, for: list, context: context,
            now: secondDate, save: { _ in
                XCTAssertEqual(list.outcomeRecord?.kind, .tradeAndPurchase)
                throw InjectedFailure.saveRefused
            }))
        XCTAssertEqual(list.transactionOutcomeData, previous); XCTAssertEqual(list.outcomeRecord?.recordedAt, firstDate)
        XCTAssertEqual(list.name, "Unsaved rename")
        XCTAssertTrue(context.insertedModelsArray.contains { ($0 as? CardList)?.id == otherID })
        let persistedContext = ModelContext(container)
        let persisted = try XCTUnwrap(persistedContext.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertEqual(persisted.name, "Original name"); XCTAssertEqual(persisted.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CardList>()), 1)
        try ListOutcomeService.set(.tradeAndPurchase, for: list, context: context, now: secondDate)
        let reopened = ModelContext(container)
        let stored = try XCTUnwrap(reopened.fetch(FetchDescriptor<CardList>()).first { $0.id == list.id })
        XCTAssertEqual(stored.name, "Unsaved rename"); XCTAssertEqual(stored.outcomeRecord?.kind, .tradeAndPurchase)
        XCTAssertEqual(stored.outcomeRecord?.recordedAt, secondDate)
        XCTAssertTrue(try reopened.fetch(FetchDescriptor<CardList>()).contains { $0.id == otherID })
    }

    func testFailedClearRetainsRecordedOutcomeUntilSuccessfulRetry() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "List"); context.insert(list); try context.save()
        try ListOutcomeService.set(.nothingHappened, for: list, context: context, now: firstDate)
        let before = list.transactionOutcomeData
        XCTAssertThrowsError(try ListOutcomeService.set(nil, for: list, context: context,
            save: { _ in throw InjectedFailure.saveRefused }))
        XCTAssertEqual(list.transactionOutcomeData, before); XCTAssertEqual(list.outcomeTitle, "Nothing Happened")
        try ListOutcomeService.set(nil, for: list, context: context)
        XCTAssertNil(list.transactionOutcomeData); XCTAssertEqual(list.outcomeTitle, "No status")
    }

    func testMarkingDoesNotChangeCardsSessionLifecycleRatesOrSavedOffers() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        for card in [candidate("p:100", price: 2), candidate("p:200", price: nil), candidate("p:100", price: 2)] {
            try SessionService.add(card, session: session, list: list, context: context)
        }
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 3)
        let ids = list.orderedCards.map(\.id), dates = list.orderedCards.map(\.addedAt)
        let data = list.orderedCards.map(\.data), offers = session.savedOffersData, rates = session.rates
        let started = session.startedAt, sessionID = session.id, listID = list.id, ref = session.lastConsumedRecognitionRef
        let quantity = session.addedQuantity, value = session.knownValueText, unpriced = session.unpricedQuantity
        for kind in ListOutcomeKind.allCases {
            try ListOutcomeService.set(kind, for: list, context: context, now: firstDate)
            XCTAssertEqual(list.orderedCards.map(\.id), ids); XCTAssertEqual(list.orderedCards.map(\.addedAt), dates)
            XCTAssertEqual(list.orderedCards.map(\.data), data); XCTAssertEqual(list.quantity, 3)
            XCTAssertEqual(session.id, sessionID); XCTAssertEqual(session.listID, listID); XCTAssertEqual(session.startedAt, started)
            XCTAssertTrue(session.isActive); XCTAssertNil(session.completedAt); XCTAssertEqual(session.rates, rates)
            XCTAssertEqual(session.lastConsumedRecognitionRef, ref); XCTAssertEqual(session.savedOffersData, offers)
            XCTAssertEqual(session.addedQuantity, quantity); XCTAssertEqual(session.knownValueText, value)
            XCTAssertEqual(session.unpricedQuantity, unpriced)
        }
    }

    func testCompletedAndResumedListRetainsExplicitOutcome() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        try SessionService.finish(session, context: context)
        let completedAt = session.completedAt
        try ListOutcomeService.set(.trade, for: list, context: context, now: firstDate)
        let outcome = list.transactionOutcomeData
        XCTAssertFalse(session.isActive); XCTAssertEqual(session.completedAt, completedAt)
        let resumed = try SessionService.continueList(list, game: "Pokémon", context: context)
        XCTAssertEqual(resumed.id, session.id); XCTAssertTrue(resumed.isActive)
        XCTAssertEqual(list.transactionOutcomeData, outcome)
        try SessionService.add(candidate("p:100", price: 2), session: resumed, list: list, context: context)
        XCTAssertEqual(list.transactionOutcomeData, outcome)
    }

    func testDuplicateListStartsUnmarkedAndPreservesOriginalOutcomeAndQuantities() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Inventory"); context.insert(list)
        let item = try InventoryCard(card: candidate("p:100", price: 2), quantity: 3)
        context.insert(item); list.cards.append(item); try context.save()
        try ListOutcomeService.set(.tradeAndPurchase, for: list, context: context, now: firstDate)
        let outcome = list.transactionOutcomeData
        try CardListService.duplicate(list, context: context)
        let copy = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first { $0.id != list.id })
        XCTAssertNil(copy.transactionOutcomeData); XCTAssertEqual(copy.outcomeTitle, "No status")
        XCTAssertEqual(copy.cards.first?.quantity, 3); XCTAssertEqual(copy.cards.first?.snapshot, item.snapshot)
        XCTAssertEqual(list.transactionOutcomeData, outcome)
    }

    func testCorruptUnknownAndOversizedMetadataFailsClosedWithoutInventingNoStatus() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "List"); context.insert(list); try context.save()
        let invalid = [Data("not JSON".utf8),
            Data(#"{"version":2,"kind":"purchase","recordedAt":0}"#.utf8),
            Data(#"{"version":1,"kind":"sold","recordedAt":0}"#.utf8),
            Data(#"{"version":1,"kind":"purchase","recordedAt":"yesterday"}"#.utf8),
            try JSONSerialization.data(withJSONObject: ["version": 1, "kind": "purchase", "recordedAt": 0,
                                                        "padding": String(repeating: "x", count: 5000)])]
        for data in invalid {
            list.transactionOutcomeData = data; try context.save()
            XCTAssertNil(list.outcomeRecord); XCTAssertEqual(list.outcomeTitle, "Status unavailable")
            XCTAssertEqual(list.transactionOutcomeData, data)
        }
        try ListOutcomeService.set(.purchase, for: list, context: context, now: firstDate)
        XCTAssertEqual(list.outcomeRecord?.kind, .purchase)
        try ListOutcomeService.set(nil, for: list, context: context)
        XCTAssertEqual(list.outcomeTitle, "No status")
    }

    func testInvalidTimestampAndUnsupportedEncodedVersionCannotReplaceExistingState() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "List"); context.insert(list); try context.save()
        try ListOutcomeService.set(.purchase, for: list, context: context, now: firstDate)
        let previous = list.transactionOutcomeData
        XCTAssertThrowsError(try ListOutcomeService.set(.trade, for: list, context: context,
            now: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(list.transactionOutcomeData, previous)
        XCTAssertThrowsError(try JSONEncoder().encode(ListOutcomeRecord(kind: .trade, recordedAt: firstDate, version: 99)))
        XCTAssertEqual(list.outcomeRecord?.kind, .purchase)
    }

    func testReleasedV2StoreMigratesToV3WithoutChangingInventorySessionsOrOffers() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("released-v2.store")
        let a = candidate("p:100", price: Decimal(string: "1.23")), b = candidate("p:200", price: nil)
        let data = try [a, b, a].map { try JSONEncoder().encode($0) }
        let totals = OfferTotals(quantity: 5, unpricedQuantity: 1, market: Decimal(string: "4.92")!, cash: 3,
                                 trade: 4, maximum: Decimal(string: "4.43")!)
        let lines = [a, b, a].enumerated().map { index, card in
            SavedOfferLine(inventoryID: UUID(), name: card.name, productID: card.identity.productID,
                printing: card.identity.printing, condition: card.identity.condition, language: card.identity.language,
                price: card.marketPrice, quantity: index == 0 ? 3 : 1, cashOverride: 2, tradeOverride: 3, maximumOverride: 4)
        }
        let offers = try JSONEncoder().encode([OfferSnapshot(rates: OfferRates(cash: 67, trade: 82, maximum: 90),
            totals: totals, lines: lines, customCashOffer: Decimal(string: "3.33"))])
        struct Fixture {
            let listID: UUID, emptyListID: UUID, sessionID: UUID, historyID: UUID
            let cardIDs: [UUID], addedAt: [Date]
        }
        func writeV2() throws -> Fixture {
            let schema = Schema(versionedSchema: ScannerSchemaV2.self)
            let configuration = ModelConfiguration("default", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration]), context = container.mainContext
            let list = ScannerSchemaV2.CardList(name: "Released V2 inventory"); list.createdAt = firstDate
            let empty = ScannerSchemaV2.CardList(name: "Standalone old list"); empty.createdAt = secondDate
            context.insert(list); context.insert(empty)
            var rows: [ScannerSchemaV2.InventoryCard] = []
            for (index, value) in data.enumerated() {
                let row = ScannerSchemaV2.InventoryCard(data: value, quantity: index == 0 ? 3 : 1)
                row.addedAt = firstDate.addingTimeInterval(Double(index + 1))
                row.cashOverrideText = "2.25"; row.tradeOverrideText = index == 1 ? nil : "3.50"
                row.maximumOverrideText = "4.75"
                context.insert(row); list.cards.append(row); rows.append(row)
            }
            let session = ScannerSchemaV2.ScanSession(listName: list.name)
            session.startedAt = firstDate; session.addedQuantity = 5; session.knownValueText = "4.92"; session.unpricedQuantity = 1
            session.listID = list.id; session.game = "Pokémon"; session.statusRaw = "active"
            session.cashRateText = "67"; session.tradeRateText = "82"; session.maximumRateText = "90"
            session.savedOffersData = offers; session.lastConsumedRecognitionRef = "p:100"
            let history = ScannerSchemaV2.ScanSession(listName: "Archived history")
            history.startedAt = firstDate.addingTimeInterval(-100); history.completedAt = secondDate
            history.addedQuantity = 9; history.knownValueText = "99.99"; history.unpricedQuantity = 3
            context.insert(session); context.insert(history); try context.save()
            return Fixture(listID: list.id, emptyListID: empty.id, sessionID: session.id, historyID: history.id,
                           cardIDs: rows.map(\.id), addedAt: rows.map(\.addedAt))
        }
        let expected = try writeV2()
        let migrated = try AppPersistence.open(url: url), context = migrated.mainContext
        let lists = try context.fetch(FetchDescriptor<CardList>()), sessions = try context.fetch(FetchDescriptor<ScanSession>())
        XCTAssertEqual(lists.count, 2); XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 3)
        XCTAssertTrue(lists.allSatisfy { $0.transactionOutcomeData == nil && $0.outcomeTitle == "No status" })
        let list = try XCTUnwrap(lists.first { $0.id == expected.listID })
        XCTAssertEqual(list.name, "Released V2 inventory"); XCTAssertEqual(list.createdAt, firstDate)
        XCTAssertEqual(list.orderedCards.map(\.id), expected.cardIDs); XCTAssertEqual(list.orderedCards.map(\.addedAt), expected.addedAt)
        XCTAssertEqual(list.orderedCards.map(\.data), data); XCTAssertEqual(list.orderedCards.map(\.quantity), [3, 1, 1])
        XCTAssertEqual(list.orderedCards.map(\.snapshot), [a, b, a]); XCTAssertEqual(list.quantity, 5)
        XCTAssertEqual(list.orderedCards.map(\.cashOverrideText), ["2.25", "2.25", "2.25"])
        XCTAssertEqual(list.orderedCards.map(\.tradeOverrideText), ["3.50", nil, "3.50"])
        XCTAssertEqual(list.orderedCards.map(\.maximumOverrideText), ["4.75", "4.75", "4.75"])
        XCTAssertTrue(list.cards.allSatisfy { $0.list?.id == expected.listID })
        let empty = try XCTUnwrap(lists.first { $0.id == expected.emptyListID })
        XCTAssertEqual(empty.name, "Standalone old list"); XCTAssertEqual(empty.createdAt, secondDate); XCTAssertTrue(empty.cards.isEmpty)
        let session = try XCTUnwrap(sessions.first { $0.id == expected.sessionID })
        XCTAssertEqual(session.startedAt, firstDate); XCTAssertEqual(session.listName, list.name)
        XCTAssertEqual(session.addedQuantity, 5); XCTAssertEqual(session.knownValueText, "4.92"); XCTAssertEqual(session.unpricedQuantity, 1)
        XCTAssertEqual(session.listID, expected.listID); XCTAssertEqual(session.game, "Pokémon"); XCTAssertEqual(session.statusRaw, "active")
        XCTAssertNil(session.completedAt); XCTAssertEqual(session.cashRateText, "67"); XCTAssertEqual(session.tradeRateText, "82")
        XCTAssertEqual(session.maximumRateText, "90"); XCTAssertEqual(session.savedOffersData, offers)
        XCTAssertEqual(session.lastConsumedRecognitionRef, "p:100"); XCTAssertEqual(try session.savedOffers().first?.lines.count, 3)
        XCTAssertEqual(try session.savedOffers().first?.customCashOffer, Decimal(string: "3.33"))
        let history = try XCTUnwrap(sessions.first { $0.id == expected.historyID })
        XCTAssertEqual(history.listName, "Archived history"); XCTAssertEqual(history.startedAt, firstDate.addingTimeInterval(-100))
        XCTAssertEqual(history.completedAt, secondDate); XCTAssertEqual(history.addedQuantity, 9)
        XCTAssertEqual(history.knownValueText, "99.99"); XCTAssertEqual(history.unpricedQuantity, 3)
        XCTAssertNil(history.listID); XCTAssertNil(history.game); XCTAssertEqual(history.statusRaw, "completed")
        XCTAssertNil(history.cashRateText); XCTAssertNil(history.tradeRateText); XCTAssertNil(history.maximumRateText)
        XCTAssertNil(history.savedOffersData); XCTAssertNil(history.lastConsumedRecognitionRef)
        try ListOutcomeService.set(.purchase, for: list, context: context, now: secondDate)
        XCTAssertEqual(list.outcomeRecord?.kind, .purchase); XCTAssertEqual(session.savedOffersData, offers)
        XCTAssertNil(empty.transactionOutcomeData)
    }
}
