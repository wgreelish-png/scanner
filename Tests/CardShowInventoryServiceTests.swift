import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowInventoryServiceTests: XCTestCase {
    private enum SaveFailure: Error { case refused }
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private let second = Date(timeIntervalSince1970: 1_700_003_600)

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func card(_ number: Int = 42, price: Decimal? = 7) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:\(number)", skuID: "\(number * 100)", printing: "Holofoil"),
                      name: "Synthetic \(number)", set: "Synthetic set", number: "\(number)", marketPrice: price,
                      confidence: 100, printings: ["Holofoil"])
    }
    private func row(_ id: Int, quantity: Int = 1, product: Int = 42, price: Decimal? = 7) -> CardShowInventoryRow {
        .init(inventoryID: id, card: card(product, price: price), quantity: quantity)
    }
    private func snapshot(_ rows: [CardShowInventoryRow], at date: Date? = nil, location: Int = 259401) -> CardShowInventorySnapshot {
        .init(location: .init(id: location, name: "Card Show"), rows: rows, fetchedAt: date ?? first)
    }
    private func folder() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func testInitialImportPreserves92Rows99CopiesAndFirstSeenOrder() async throws {
        let container = try store(), context = container.mainContext
        let rows = (0..<92).map { index in row(index + 1, quantity: index < 86 ? 1 : (index < 91 ? 2 : 3), product: index + 42) }
        let list = try CardShowInventoryService.apply(snapshot(rows), context: context)
        XCTAssertEqual(list.name, "Card Show"); XCTAssertTrue(list.isCardShowInventory)
        XCTAssertEqual(list.cards.count, 92); XCTAssertEqual(list.quantity, 99)
        XCTAssertEqual(list.orderedCards.compactMap(\.sourceInventoryID), Array(1...92))
        XCTAssertEqual(list.orderedCards.map(\.quantity), rows.map(\.quantity))
        XCTAssertEqual(list.cardShowInventory?.locationID, 259401)
        XCTAssertEqual(list.cardShowInventory?.refreshedAt, first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScanSession>()), 0)
    }

    func testRepeatedRefreshUpdatesSourceRowsWithoutMergingExactDuplicatesOrChangingLocalIdentity() async throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot([row(10, quantity: 2), row(20)]), context: context)
        let originalID = list.id, rows = list.orderedCards, ids = rows.map(\.id), dates = rows.map(\.addedAt)
        rows[0].cashOverrideText = "4"; rows[0].tradeOverrideText = "5"; rows[0].maximumOverrideText = "6"
        list.name = "My show stock"
        try ListOutcomeService.set(.purchase, for: list, context: context, now: first)
        let outcome = list.transactionOutcomeData
        let session = ScanSession(listName: list.name); session.listID = list.id
        session.savedOffersData = Data("[]".utf8); context.insert(session); try context.save()
        let offers = session.savedOffersData
        let changed = snapshot([row(20, quantity: 4, price: 0), row(10, quantity: 3, price: nil), row(30)], at: second)
        for _ in 0..<3 { try CardShowInventoryService.apply(changed, context: context) }
        XCTAssertEqual(list.id, originalID); XCTAssertEqual(list.name, "My show stock")
        XCTAssertEqual(list.orderedCards.prefix(2).map(\.id), ids)
        XCTAssertEqual(list.orderedCards.prefix(2).map(\.addedAt), dates)
        XCTAssertEqual(list.orderedCards.compactMap(\.sourceInventoryID), [10, 20, 30])
        XCTAssertEqual(list.orderedCards.map(\.quantity), [3, 4, 1])
        XCTAssertNil(list.orderedCards[0].snapshot.marketPrice)
        XCTAssertEqual(list.orderedCards[1].snapshot.marketPrice, 0)
        XCTAssertEqual(rows[0].cashOverrideText, "4"); XCTAssertEqual(rows[0].tradeOverrideText, "5")
        XCTAssertEqual(rows[0].maximumOverrideText, "6"); XCTAssertEqual(list.transactionOutcomeData, outcome)
        XCTAssertEqual(session.savedOffersData, offers); XCTAssertEqual(list.cardShowInventory?.refreshedAt, second)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 3)
    }

    func testCompleteEmptyRefreshRemovesOnlyImportedRowsAndRetainsTheList() async throws {
        let container = try store(), context = container.mainContext
        let ordinary = CardList(name: "Other inventory"); context.insert(ordinary)
        try CardListService.add(card(), to: ordinary, context: context); try context.save()
        let imported = try CardShowInventoryService.apply(snapshot([row(1), row(2, quantity: 0)]), context: context)
        let listID = imported.id
        try CardShowInventoryService.apply(snapshot([], at: second), context: context)
        XCTAssertEqual(imported.id, listID); XCTAssertEqual(imported.cards.count, 0)
        XCTAssertEqual(imported.cardShowInventory?.refreshedAt, second)
        XCTAssertEqual(ordinary.quantity, 1); XCTAssertEqual(ordinary.cards.first?.snapshot, card())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 1)
    }

    func testFailedInitialSaveLeavesNoPhantomListAndCanRetry() async throws {
        let container = try store(), context = container.mainContext
        XCTAssertThrowsError(try CardShowInventoryService.apply(snapshot([row(1)]), context: context, save: { _ in throw SaveFailure.refused }))
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 0)
        XCTAssertFalse(context.hasChanges)
        let list = try CardShowInventoryService.apply(snapshot([row(1)]), context: context)
        XCTAssertEqual(list.quantity, 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
    }

    func testFailedRefreshRestoresChangedRemovedAndInsertedRowsBeforeRetry() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("inventory-rollback.store")
        let container = try AppPersistence.open(url: url), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot([row(1, quantity: 3), row(2)]), context: context)
        let before = list.orderedCards.map(\.data), ids = list.orderedCards.map(\.id), dates = list.orderedCards.map(\.addedAt)
        let source = list.inventorySourceData
        list.orderedCards[0].cashOverrideText = "4"; try context.save()
        let changed = snapshot([row(1, quantity: 2, price: 99), row(3, quantity: 4)], at: second)
        XCTAssertThrowsError(try CardShowInventoryService.apply(changed, context: context, save: { context in
            context.processPendingChanges(); throw SaveFailure.refused
        }))
        XCTAssertEqual(list.inventorySourceData, source); XCTAssertEqual(list.orderedCards.map(\.id), ids)
        XCTAssertEqual(list.orderedCards.map(\.data), before); XCTAssertEqual(list.orderedCards.map(\.quantity), [3, 1])
        XCTAssertEqual(list.orderedCards.map(\.addedAt), dates); XCTAssertEqual(list.orderedCards[0].cashOverrideText, "4")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 2)
        XCTAssertFalse(context.hasChanges)
        let disk = try AppPersistence.open(url: url)
        let cached = try XCTUnwrap(CardShowInventoryService.importedList(context: disk.mainContext))
        XCTAssertEqual(cached.id, list.id); XCTAssertEqual(cached.inventorySourceData, source)
        XCTAssertEqual(cached.orderedCards.map(\.data), before)
        try CardShowInventoryService.apply(changed, context: context)
        XCTAssertEqual(list.orderedCards.compactMap(\.sourceInventoryID), [1, 3])
        XCTAssertEqual(list.orderedCards.map(\.quantity), [2, 4]); XCTAssertEqual(list.orderedCards[0].id, ids[0])
    }

    func testLocationChangeDuplicateIDsAndInvalidQuantityNeverMutateTheCachedList() async throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot([row(1)]), context: context)
        let data = list.cards[0].data, source = list.inventorySourceData
        XCTAssertThrowsError(try CardShowInventoryService.apply(snapshot([row(2)], location: 259402), context: context)) { error in
            XCTAssertEqual(error as? CardShowInventoryFailure, .locationChanged)
        }
        for invalid in [snapshot([row(1), row(1)]), snapshot([row(2, quantity: -1)]), snapshot([row(2)], location: 0)] {
            XCTAssertThrowsError(try CardShowInventoryService.apply(invalid, context: context))
        }
        XCTAssertEqual(list.inventorySourceData, source); XCTAssertEqual(list.cards.count, 1)
        XCTAssertEqual(list.cards[0].data, data); XCTAssertEqual(list.quantity, 1)
    }

    func testOrdinaryCardShowNamedListIsNeverHijackedAndCorruptSourceLinkFailsClosed() async throws {
        let container = try store(), context = container.mainContext
        let ordinary = CardList(name: "Card Show"); context.insert(ordinary); try context.save()
        let imported = try CardShowInventoryService.apply(snapshot([row(1)]), context: context)
        XCTAssertNotEqual(imported.id, ordinary.id); XCTAssertNil(ordinary.inventorySourceData)
        imported.inventorySourceData = Data("unsupported".utf8); try context.save()
        XCTAssertTrue(imported.isCardShowInventory); XCTAssertNil(imported.cardShowInventory)
        XCTAssertThrowsError(try CardShowInventoryService.importedList(context: context))
        XCTAssertThrowsError(try CardShowInventoryService.apply(snapshot([]), context: context))
        XCTAssertEqual(imported.quantity, 1)
    }

    func testUnlinkedForeignRowCannotBeErasedByRefresh() async throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot([row(1)]), context: context)
        let foreign = try InventoryCard(card: card(999)); context.insert(foreign); list.cards.append(foreign)
        try context.save()
        XCTAssertThrowsError(try CardShowInventoryService.apply(snapshot([]), context: context))
        XCTAssertEqual(list.cards.count, 2); XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 2)
    }

    func testReadOnlyMirrorCanBeDuplicatedToAnEditableIndependentList() async throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot([row(1, quantity: 2), row(2)]), context: context)
        XCTAssertThrowsError(try CardListService.add(card(999), to: imported, context: context))
        let item = try XCTUnwrap(imported.cards.first)
        XCTAssertThrowsError(try CardListService.edit(item, card: card(999), quantity: 1,
            cashOverride: nil, tradeOverride: nil, maximumOverride: nil, context: context))
        try CardListService.duplicate(imported, context: context)
        let copy = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first { $0.id != imported.id })
        XCTAssertFalse(copy.isCardShowInventory); XCTAssertNil(copy.inventorySourceData)
        XCTAssertTrue(copy.cards.allSatisfy { $0.sourceInventoryID == nil })
        XCTAssertEqual(copy.orderedCards.map(\.snapshot), imported.orderedCards.map(\.snapshot))
        XCTAssertEqual(copy.orderedCards.map(\.quantity), imported.orderedCards.map(\.quantity))
        try CardListService.add(card(999), to: copy, context: context); try context.save()
        XCTAssertEqual(copy.cards.count, 3); XCTAssertEqual(imported.cards.count, 2)
    }

    func testCachedSourceIdentityAndQuantitiesSurviveReopenAndLocalDeletion() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("inventory-offline.store")
        func write() throws -> (UUID, [UUID]) {
            let container = try AppPersistence.open(url: url)
            let list = try CardShowInventoryService.apply(snapshot([row(2, quantity: 3), row(1)]), context: container.mainContext)
            return (list.id, list.orderedCards.map(\.id))
        }
        let expected = try write(), container = try AppPersistence.open(url: url), context = container.mainContext
        let list = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(list.id, expected.0); XCTAssertEqual(list.orderedCards.map(\.id), expected.1)
        XCTAssertEqual(list.orderedCards.compactMap(\.sourceInventoryID), [2, 1])
        XCTAssertEqual(list.orderedCards.map(\.quantity), [3, 1]); XCTAssertEqual(list.cardShowInventory?.refreshedAt, first)
        try SessionService.deleteList(id: list.id, context: context)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 0)
    }

    func testDirtyUnrelatedDraftIsNotSavedOrRolledBackByImport() async throws {
        let container = try store(), context = container.mainContext
        let ordinary = CardList(name: "Uncommitted draft"); context.insert(ordinary)
        XCTAssertThrowsError(try CardShowInventoryService.apply(snapshot([row(1)]), context: context))
        XCTAssertEqual(ordinary.name, "Uncommitted draft"); XCTAssertTrue(context.hasChanges)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
    }

    func testReleasedV3StoreMigratesWithoutChangingOutcomesOrderQuantitiesOrSavedOffers() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("released-v3.store")
        let a = card(42), b = card(43, price: nil)
        let encoded = try [a, b, a].map { try JSONEncoder().encode($0) }
        let outcome = try JSONEncoder().encode(ListOutcomeRecord(kind: .tradeAndPurchase, recordedAt: second))
        let offers = Data("[]".utf8)
        struct Expected { let list: UUID, session: UUID; let rows: [UUID], dates: [Date] }
        func writeV3() throws -> Expected {
            let schema = Schema(versionedSchema: ScannerSchemaV3.self)
            let configuration = ModelConfiguration("default", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration]), context = container.mainContext
            let list = ScannerSchemaV3.CardList(name: "Released V3 inventory"); list.createdAt = first
            list.transactionOutcomeData = outcome; context.insert(list)
            var rows: [ScannerSchemaV3.InventoryCard] = []
            for (index, data) in encoded.enumerated() {
                let row = ScannerSchemaV3.InventoryCard(data: data, quantity: index == 0 ? 3 : 1)
                row.addedAt = first.addingTimeInterval(Double(index)); row.cashOverrideText = "4"
                row.tradeOverrideText = "5"; row.maximumOverrideText = "6"
                context.insert(row); list.cards.append(row); rows.append(row)
            }
            let session = ScannerSchemaV3.ScanSession(listName: list.name)
            session.listID = list.id; session.statusRaw = "active"; session.game = "Pokémon"
            session.savedOffersData = offers; session.lastConsumedRecognitionRef = "p:42"
            session.cashRateText = "70"; session.tradeRateText = "80"; session.maximumRateText = "75"
            context.insert(session); try context.save()
            return Expected(list: list.id, session: session.id, rows: rows.map(\.id), dates: rows.map(\.addedAt))
        }
        let expected = try writeV3(), migrated = try AppPersistence.open(url: url), context = migrated.mainContext
        let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertEqual(list.id, expected.list); XCTAssertEqual(list.createdAt, first)
        XCTAssertEqual(list.transactionOutcomeData, outcome); XCTAssertEqual(list.outcomeRecord?.kind, .tradeAndPurchase)
        XCTAssertNil(list.inventorySourceData); XCTAssertFalse(list.isCardShowInventory)
        XCTAssertEqual(list.orderedCards.map(\.id), expected.rows); XCTAssertEqual(list.orderedCards.map(\.addedAt), expected.dates)
        XCTAssertEqual(list.orderedCards.map(\.data), encoded); XCTAssertEqual(list.orderedCards.map(\.quantity), [3, 1, 1])
        XCTAssertTrue(list.cards.allSatisfy { $0.sourceInventoryID == nil && $0.list?.id == list.id })
        XCTAssertTrue(list.cards.allSatisfy { $0.cashOverrideText == "4" && $0.tradeOverrideText == "5" && $0.maximumOverrideText == "6" })
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<ScanSession>()).first)
        XCTAssertEqual(session.id, expected.session); XCTAssertEqual(session.listID, expected.list)
        XCTAssertEqual(session.statusRaw, "active"); XCTAssertEqual(session.game, "Pokémon")
        XCTAssertEqual(session.savedOffersData, offers); XCTAssertEqual(session.lastConsumedRecognitionRef, "p:42")
        XCTAssertEqual(session.cashRateText, "70"); XCTAssertEqual(session.tradeRateText, "80"); XCTAssertEqual(session.maximumRateText, "75")
        let imported = try CardShowInventoryService.apply(snapshot([row(1)]), context: context)
        XCTAssertNotEqual(imported.id, list.id); XCTAssertEqual(list.orderedCards.map(\.data), encoded)
    }
}
