import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ShowTransactionListServiceTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let disk: Disk
        let store: ShowBudgetStore
        let showID: UUID
        let list: CardList
    }

    private func card(_ id: String = "incoming", price: Decimal? = 100) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: id, printing: "Normal"),
            name: "Synthetic " + id, set: "Fixture", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"])
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func budgetStore(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-show-budget.json"),
            read: { _ in disk.data }, write: { data, _ in
                disk.writes += 1
                disk.data = data
            }, now: { disk.now })
    }

    private func list(_ cards: [(CardCandidate, Int)], name: String = "Incoming fixture",
                      context: ModelContext) throws -> CardList {
        let result = CardList(name: name)
        context.insert(result)
        for (candidate, quantity) in cards {
            let row = try InventoryCard(card: candidate, quantity: quantity)
            context.insert(row)
            result.cards.append(row)
        }
        return result
    }

    private func fixture() throws -> Fixture {
        let container = try container(), context = container.mainContext
        context.autosaveEnabled = false
        let disk = Disk(), store = budgetStore(disk)
        let showID = try store.create(name: "Synthetic show", startingCents: 30_000)
        let list = try list([(card(), 2)], context: context)
        try context.save()
        return .init(container: container, context: context, disk: disk,
            store: store, showID: showID, list: list)
    }

    private func purchase(_ list: CardList) throws -> ShowTransactionDraft {
        .init(kind: .purchase, incomingListID: list.id, incomingListName: list.name,
            incoming: try ShowTransactionListService.incomingCards(for: list), incomingValueCents: 14_000)
    }

    private func assertRejected(_ draft: ShowTransactionDraft, as expected: ShowTransactionListFailure,
                                in fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let before = fixture.store.book, data = fixture.disk.data, writes = fixture.disk.writes
        XCTAssertThrowsError(try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store), file: file, line: line) {
                XCTAssertEqual($0 as? ShowTransactionListFailure, expected, file: file, line: line)
            }
        XCTAssertEqual(fixture.store.book, before, file: file, line: line)
        XCTAssertEqual(fixture.disk.data, data, file: file, line: line)
        XCTAssertEqual(fixture.disk.writes, writes, file: file, line: line)
    }

    func testUnsetSessionRatesSuggestSeventyPercentCashAndEightyPercentTrade() throws {
        let fixture = try fixture()
        let session = ScanSession(listName: fixture.list.name)
        session.listID = fixture.list.id
        fixture.context.insert(session)
        try fixture.context.save()

        XCTAssertEqual(try ShowTransactionListService.defaultIncomingValue(for: fixture.list,
            kind: .purchase, context: fixture.context), 14_000)
        for kind in [ShowTransactionKind.trade, .tradePayCustomer, .tradeReceiveCash] {
            XCTAssertEqual(try ShowTransactionListService.defaultIncomingValue(for: fixture.list,
                kind: kind, context: fixture.context), 16_000)
        }
        XCTAssertEqual(fixture.list.knownValue, 200)
        XCTAssertTrue(fixture.store.transactions.isEmpty)
    }

    func testLatestMatchingSessionAndPerCardOverridesDetermineSuggestions() throws {
        let fixture = try fixture()
        let overridden = try XCTUnwrap(fixture.list.cards.first)
        overridden.cashOverrideText = "55"
        overridden.tradeOverrideText = "85"
        let other = try InventoryCard(card: card("other", price: 20), quantity: 3)
        fixture.context.insert(other)
        fixture.list.cards.append(other)
        for (offset, listID, rates) in [
            (-100.0, fixture.list.id, OfferRates(cash: 10, trade: 20, maximum: 30)),
            (0.0, fixture.list.id, OfferRates(cash: 50, trade: 90, maximum: 75)),
            (100.0, UUID(), OfferRates(cash: 100, trade: 100, maximum: 100))
        ] {
            let session = ScanSession(listName: "Synthetic session")
            session.listID = listID
            session.startedAt = fixture.disk.now.addingTimeInterval(offset)
            session.setRates(rates)
            fixture.context.insert(session)
        }
        try fixture.context.save()

        XCTAssertEqual(try ShowTransactionListService.defaultIncomingValue(for: fixture.list,
            kind: .purchase, context: fixture.context), 14_000)
        XCTAssertEqual(try ShowTransactionListService.defaultIncomingValue(for: fixture.list,
            kind: .trade, context: fixture.context), 22_400)
        XCTAssertEqual(overridden.snapshot.marketPrice, 100)
        XCTAssertEqual(other.snapshot.marketPrice, 20)
    }

    func testUnpricedLotHasNoSuggestedAmountWhileKnownZeroIsZero() throws {
        let container = try container(), context = container.mainContext
        context.autosaveEnabled = false
        let mixed = try list([(card("priced", price: 10), 1), (card("unknown", price: nil), 2)], context: context)
        let zero = try list([(card("zero", price: 0), 3)], name: "Known zero", context: context)
        try context.save()

        for kind in [ShowTransactionKind.purchase, .trade] {
            XCTAssertNil(try ShowTransactionListService.defaultIncomingValue(for: mixed, kind: kind, context: context))
            XCTAssertEqual(try ShowTransactionListService.defaultIncomingValue(for: zero, kind: kind, context: context), 0)
        }
        XCTAssertEqual(mixed.knownValue, 10)
        XCTAssertEqual(mixed.unpricedQuantity, 2)
        XCTAssertEqual(zero.unpricedQuantity, 0)
    }

    func testDirtyContextMissingSourceAndChangedSourceCannotMoveCashOrStock() throws {
        let fixture = try fixture(), draft = try purchase(fixture.list)
        fixture.list.name = "Unsaved rename"
        assertRejected(draft, as: .unsavedChanges, in: fixture)
        fixture.context.rollback()

        var missingID = draft
        missingID.incomingListID = nil
        missingID.incomingListName = nil
        assertRejected(missingID, as: .listUnavailable, in: fixture)
        var missingList = draft
        missingList.incomingListID = UUID()
        assertRejected(missingList, as: .listUnavailable, in: fixture)

        let row = try XCTUnwrap(fixture.list.cards.first)
        row.quantity += 1
        try fixture.context.save()
        assertRejected(draft, as: .sourceChanged, in: fixture)
        row.quantity -= 1
        fixture.list.name = "Saved rename"
        try fixture.context.save()
        assertRejected(draft, as: .sourceChanged, in: fixture)
        XCTAssertTrue(fixture.store.inventory.isEmpty)
        XCTAssertTrue(fixture.store.activeShow?.entries.isEmpty == true)
    }

    func testCorruptOutcomeFailsClosedButExplicitNothingHappenedAllowsPurchase() throws {
        let fixture = try fixture(), draft = try purchase(fixture.list)
        fixture.list.transactionOutcomeData = Data("invalid synthetic outcome".utf8)
        try fixture.context.save()
        XCTAssertNil(fixture.list.outcomeRecord)
        assertRejected(draft, as: .alreadyRecorded, in: fixture)

        let outcome = try JSONEncoder().encode(ListOutcomeRecord(kind: .nothingHappened, recordedAt: fixture.disk.now))
        fixture.list.transactionOutcomeData = outcome
        try fixture.context.save()
        let receipt = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        XCTAssertEqual(receipt.paidCents, 14_000)
        XCTAssertEqual(fixture.store.inventory.map(\.quantity), [2])
        XCTAssertEqual(fixture.store.activeShow?.entries.count, 1)
        XCTAssertEqual(fixture.list.transactionOutcomeData, outcome)
        XCTAssertEqual(fixture.list.quantity, 2)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testCommittedRetryAfterSourceDeletionReturnsReceiptWithoutSecondCashOrStock() throws {
        let fixture = try fixture(), draft = try purchase(fixture.list)
        let original = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        fixture.context.delete(fixture.list)
        try fixture.context.save()
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<CardList>()), 0)
        let committed = fixture.store.book, writes = fixture.disk.writes

        let retried = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        XCTAssertEqual(retried, original)
        XCTAssertEqual(fixture.store.book, committed)
        XCTAssertEqual(fixture.disk.writes, writes)
        XCTAssertEqual(fixture.store.activeShow?.entries.count, 1)
        XCTAssertEqual(budgetStore(fixture.disk).book, committed)
    }

    func testEditingListRefreshesCardsNameQuantitiesAndCalculatedOfferBeforeRecording() throws {
        let fixture = try fixture()
        let session = ScanSession(listName: fixture.list.name)
        session.listID = fixture.list.id; session.setRates(.init(cash: 70, trade: 80, maximum: 75))
        fixture.context.insert(session); try fixture.context.save()
        let before = try ShowTransactionListService.incomingSnapshot(for: fixture.list, kind: .trade, context: fixture.context)
        XCTAssertEqual(before.defaultValueCents, 16_000)
        fixture.list.name = "Edited list"
        let row = try XCTUnwrap(fixture.list.cards.first)
        row.quantity = 3
        var changed = row.snapshot
        changed.identity.condition = "Lightly Played"; changed.marketPrice = 50
        try row.update(changed)
        try fixture.context.save()
        let after = try ShowTransactionListService.incomingSnapshot(for: fixture.list, kind: .trade, context: fixture.context)
        XCTAssertEqual(after.name, "Edited list"); XCTAssertEqual(after.cards.first?.quantity, 3)
        XCTAssertEqual(after.cards.first?.card.identity.condition, "Lightly Played")
        XCTAssertEqual(after.defaultValueCents, 12_000)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(fixture.store.transactions.isEmpty)
        XCTAssertTrue(fixture.store.inventory.isEmpty)
        XCTAssertEqual(try XCTUnwrap(fixture.store.activeShow).totals().availableCents, 30_000)
    }

    func testConsumedIncomingListCannotBeRecordedAgainWithANewOperationID() throws {
        let fixture = try fixture(), draft = try purchase(fixture.list)
        _ = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        var second = draft
        second.id = UUID()
        assertRejected(second, as: .alreadyRecorded, in: fixture)
        XCTAssertEqual(fixture.store.transactions.count, 1)
        XCTAssertEqual(fixture.list.quantity, 2)
        XCTAssertNil(fixture.list.transactionOutcomeData)
        XCTAssertEqual(ShowTransactionListService.outcomeTitle(for: fixture.list, store: fixture.store), "Purchase")
    }

    func testBridgeFreshImportReplacesWorkingQuantitiesAndSourceDeletionKeepsCommittedHistory() throws {
        let fixture = try fixture()
        let first = CardShowInventorySnapshot(location: .init(id: 9, name: "Card Show"),
            rows: [.init(inventoryID: 10, card: card("source"), quantity: 2)], fetchedAt: fixture.disk.now)
        let imported = try CardShowInventoryService.apply(first, context: fixture.context)
        try fixture.context.save()
        try ShowInventoryBridge.seedFromImportedList(context: fixture.context, store: fixture.store)
        let sourceID = try XCTUnwrap(fixture.store.inventory.first?.id)
        let sale = ShowTransactionDraft(kind: .sale, outgoing: [.init(inventoryID: sourceID, quantity: 2)],
            outgoingValueCents: 20_000, saleReceivedCents: 20_000)
        _ = try ShowTransactionListService.record(sale, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        let purchase = try ShowTransactionListService.record(purchase(fixture.list), showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        let purchasedID = try XCTUnwrap(purchase.incoming.first?.inventoryID)
        let receipts = fixture.store.transactions
        let cash = try XCTUnwrap(fixture.store.activeShow).totals()

        let refreshed = CardShowInventorySnapshot(location: first.location, rows: [
            .init(inventoryID: 10, card: card("source", price: 200), quantity: 8),
            .init(inventoryID: 20, card: card("new-remote"), quantity: 4)
        ], fetchedAt: fixture.disk.now.addingTimeInterval(60))
        try CardShowInventoryService.apply(refreshed, context: fixture.context)
        try fixture.context.save()
        XCTAssertEqual(imported.quantity, 12)
        try ShowInventoryBridge.seedFromImportedList(context: fixture.context, store: fixture.store)
        XCTAssertEqual(fixture.store.inventory.reduce(0) { $0 + $1.quantity }, 12)
        XCTAssertEqual(fixture.store.inventory.first { $0.id == sourceID }?.quantity, 0)
        XCTAssertEqual(fixture.store.inventory.first { $0.id == purchasedID }?.quantity, 0)
        XCTAssertEqual(fixture.store.inventory.filter { $0.card.identity.productID == "source" }.reduce(0) { $0 + $1.quantity }, 8)
        XCTAssertEqual(fixture.store.inventory.filter { $0.card.identity.productID == "new-remote" }.reduce(0) { $0 + $1.quantity }, 4)
        XCTAssertEqual(fixture.store.transactions, receipts)
        XCTAssertEqual(try XCTUnwrap(fixture.store.activeShow).totals(), cash)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, false)
        let committed = fixture.store.book, writes = fixture.disk.writes

        fixture.context.delete(imported)
        try fixture.context.save()
        try ShowInventoryBridge.seedFromImportedList(context: fixture.context, store: fixture.store)
        XCTAssertEqual(fixture.store.book, committed)
        XCTAssertEqual(fixture.disk.writes, writes)
        XCTAssertEqual(fixture.store.inventorySourceLocationID, 9)
        XCTAssertEqual(budgetStore(fixture.disk).book, committed)
    }
    func testIncomingCostWeightsRespectOfferOverridesAndNegotiatedPaymentWithoutEditingSource() throws {
        let fixture = try fixture()
        let first = try XCTUnwrap(fixture.list.cards.first)
        first.cashOverrideText = "55"; first.tradeOverrideText = "85"
        let other = try InventoryCard(card: card("weighted", price: 20), quantity: 3)
        fixture.context.insert(other); fixture.list.cards.append(other)
        let session = ScanSession(listName: fixture.list.name)
        session.listID = fixture.list.id; session.setRates(.init(cash: 50, trade: 90, maximum: 75))
        fixture.context.insert(session); try fixture.context.save()
        let source = fixture.list.orderedCards.map(\.snapshot)
        let snapshot = try ShowTransactionListService.incomingSnapshot(for: fixture.list, kind: .purchase, context: fixture.context)
        let weights = Dictionary(uniqueKeysWithValues: snapshot.cards.map { ($0.id, $0.costWeightCents) })
        XCTAssertEqual(weights[first.id]!, 11_000)
        XCTAssertEqual(weights[other.id]!, 3_000)
        let draft = ShowTransactionDraft(kind: .purchase, incomingListID: fixture.list.id,
            incomingListName: fixture.list.name, incoming: snapshot.cards, incomingValueCents: 7_000)
        let receipt = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        XCTAssertEqual(receipt.accounting?.incoming.map(\.totalCostCents).compactMap { $0 }.sorted(), [1_500, 5_500])
        XCTAssertEqual(fixture.list.orderedCards.map(\.snapshot), source)
        XCTAssertEqual(try XCTUnwrap(fixture.store.activeShow).totals().availableCents, 23_000)
        XCTAssertEqual(fixture.store.inventory.compactMap(\.remainingCostCents).reduce(0, +), 7_000)
    }

    func testReviewedIncomingCostsMayDifferFromOfferWeightsButCannotReplaceSourceCards() throws {
        let fixture = try fixture()
        let other = try InventoryCard(card: card("second", price: 25), quantity: 1)
        fixture.context.insert(other); fixture.list.cards.append(other); try fixture.context.save()
        var rows = try ShowTransactionListService.incomingSnapshot(for: fixture.list,
            kind: .purchase, context: fixture.context).cards
        rows[0].allocatedCostCents = 1_000
        rows[1].allocatedCostCents = 6_000
        var draft = ShowTransactionDraft(kind: .purchase, incomingListID: fixture.list.id,
            incomingListName: fixture.list.name, incoming: rows, incomingValueCents: 7_000)
        draft.incoming[0].card.identity.condition = "Damaged"
        assertRejected(draft, as: .sourceChanged, in: fixture)
        draft.incoming = rows
        let receipt = try ShowTransactionListService.record(draft, showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        XCTAssertEqual(receipt.accounting?.incoming.map(\.totalCostCents), [1_000, 6_000])
        XCTAssertEqual(fixture.list.orderedCards.count, 2)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testOneUnpricedIncomingLotKeepsActualCostAndSupportsLaterOfflineSaleProfit() throws {
        let fixture = try fixture()
        let row = try XCTUnwrap(fixture.list.cards.first)
        try row.update(card(price: nil)); try fixture.context.save()
        let snapshot = try ShowTransactionListService.incomingSnapshot(for: fixture.list,
            kind: .purchase, context: fixture.context)
        XCTAssertNil(snapshot.defaultValueCents); XCTAssertNil(snapshot.cards.first?.costWeightCents)
        let purchase = try ShowTransactionListService.record(.init(kind: .purchase,
            incomingListID: fixture.list.id, incomingListName: fixture.list.name,
            incoming: snapshot.cards, incomingValueCents: 1_400), showID: fixture.showID,
            context: fixture.context, store: fixture.store)
        let acquired = try XCTUnwrap(purchase.incoming.first)
        XCTAssertEqual(fixture.store.inventory.first?.remainingCostCents, 1_400)
        let sale = try ShowTransactionListService.record(.init(kind: .sale,
            outgoing: [.init(inventoryID: acquired.inventoryID, quantity: 1)], saleReceivedCents: 1_000),
            showID: fixture.showID, context: fixture.context, store: fixture.store)
        XCTAssertEqual(sale.totalCostCents, 700); XCTAssertEqual(sale.profitCents, 300)
        XCTAssertNil(sale.outgoing.first?.card.marketPrice)
        XCTAssertEqual(fixture.store.inventory.first?.remainingCostCents, 700)
    }

}
