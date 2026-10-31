import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ListBudgetOutcomeTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var failWrites = Set<Int>()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }
    private struct Fixture {
        let container: ModelContainer
        let list: CardList
        let disk: Disk
        let store: ShowBudgetStore
        var context: ModelContext { container.mainContext }
    }
    private func fixture(show: Bool = true, scheduledOffset: TimeInterval? = nil) throws -> Fixture {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let list = try makeList(context: container.mainContext)
        let disk = Disk()
        let store = ShowBudgetStore(read: { _ in disk.data }, write: { data, _ in
            disk.writes += 1
            if disk.failWrites.contains(disk.writes) { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = data
        }, now: { disk.now })
        if show {
            let day = scheduledOffset.map { disk.now.addingTimeInterval($0) }
            try store.create(name: "Fixture show", startingCents: 30_000, startDate: day, endDate: day)
        }
        return .init(container: container, list: list, disk: disk, store: store)
    }
    private func makeList(context: ModelContext) throws -> CardList {
        let list = CardList(name: "Outcome fixture")
        context.insert(list)
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 100,
            confidence: 100, printings: ["Normal"])
        try CardListService.add(card, to: list, context: context); try context.save()
        return list
    }
    private func totals(cash: Decimal = 100, trade: Decimal = 100, unpriced: Int = 0) -> OfferTotals {
        OfferTotals(quantity: 1, unpricedQuantity: unpriced, market: 100, cash: cash, trade: trade, maximum: 100)
    }
    @discardableResult private func record(_ kind: ListOutcomeKind?, in fixture: Fixture,
        totals: OfferTotals? = nil, transaction: TradeTransactionResult? = nil,
        save: ListBudgetOutcomeService.Save? = nil) throws -> ListBudgetOutcomeResult {
        try ListBudgetOutcomeService.record(kind, totals: totals ?? self.totals(), transaction: transaction,
            for: fixture.list, context: fixture.context, store: fixture.store, save: save)
    }
    private func available(_ fixture: Fixture) throws -> Int64 {
        try XCTUnwrap(fixture.store.activeShow).totals().availableCents
    }

    func testPurchasePostsCalculatedCashOnceAndAnIdenticalTapIsACompleteNoOp() throws {
        let value = try fixture()
        let result = try record(.purchase, in: value)
        XCTAssertFalse(result.isPending); XCTAssertNil(result.message)
        XCTAssertEqual(try available(value), 20_000)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(value.store.activeShow?.entries.count, 1)
        XCTAssertEqual(value.store.book.listOutcomeUpdates?.first?.mirrored, true)
        let writes = value.disk.writes, bytes = value.disk.data, outcome = value.list.transactionOutcomeData
        try record(.purchase, in: value)
        XCTAssertEqual(value.disk.writes, writes); XCTAssertEqual(value.disk.data, bytes)
        XCTAssertEqual(value.list.transactionOutcomeData, outcome)
        XCTAssertEqual(value.store.activeShow?.entries.count, 1)
    }

    func testTradeReceivingCashUsesTheGrossSixtyFiveThirtyFiveSplit() throws {
        let value = try fixture(), offers = totals(cash: 70, trade: 80)
        let trade = try TradeTransactionCalculator.calculate(totals: offers, input: .init(mode: .tradeAndCash, myCardPrice: 280))
        try record(.tradeAndPurchase, in: value, totals: offers, transaction: trade)
        let totals = try XCTUnwrap(value.store.activeShow).totals()
        XCTAssertEqual(totals.availableCents, 43_000); XCTAssertEqual(totals.savedCents, 7_000)
        XCTAssertEqual(totals.grossReceivedCents, 20_000)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .tradeAndPurchase)
    }

    func testTradeCashPayoutDebitsOnlyTheCalculatedUnusedCashPortion() throws {
        let value = try fixture(), offers = totals(cash: 70, trade: 80)
        let trade = try TradeTransactionCalculator.calculate(totals: offers, input: .init(mode: .tradeAndCash, myCardPrice: 40))
        try record(.tradeAndPurchase, in: value, totals: offers, transaction: trade)
        XCTAssertEqual(try available(value), 26_500)
        XCTAssertEqual(value.store.activeShow?.entries.first?.paidCents, 3_500)
    }

    func testChangingCashReplacesPriorImpactAndPureTradeNothingAndClearRemoveIt() throws {
        let value = try fixture()
        try record(.purchase, in: value)
        try record(.purchase, in: value, totals: totals(cash: 80))
        XCTAssertEqual(try available(value), 22_000)
        XCTAssertEqual(value.store.activeShow?.entries.filter { $0.voidedAt == nil }.count, 1)
        try record(.trade, in: value)
        XCTAssertEqual(try available(value), 30_000)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .trade)
        try record(.nothingHappened, in: value)
        XCTAssertEqual(try available(value), 30_000)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .nothingHappened)
        try record(nil, in: value)
        XCTAssertNil(value.list.transactionOutcomeData)
        XCTAssertEqual(try available(value), 30_000)
        XCTAssertEqual(value.store.book.listOutcomeUpdates?.count, 1)
    }

    func testChangingCashCannotMoveAnOldExpenseIntoAnotherSelectedShow() throws {
        let value = try fixture()
        try record(.purchase, in: value)
        let firstShow = try XCTUnwrap(value.store.activeShow).id
        let secondShow = try value.store.create(name: "Another show", startingCents: 30_000)
        let bytes = value.disk.data, outcome = value.list.transactionOutcomeData
        try record(.purchase, in: value)
        XCTAssertEqual(value.disk.data, bytes, "Identical retry does not move the old receipt")
        XCTAssertThrowsError(try record(.purchase, in: value, totals: totals(cash: 80))) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .differentShowReplacement)
        }
        XCTAssertEqual(value.list.transactionOutcomeData, outcome)
        XCTAssertEqual(try value.store.book.shows.first(where: { $0.id == firstShow })?.totals().availableCents, 20_000)
        XCTAssertEqual(try value.store.book.shows.first(where: { $0.id == secondShow })?.totals().availableCents, 30_000)
        try record(nil, in: value)
        try record(.purchase, in: value, totals: totals(cash: 80))
        XCTAssertEqual(try value.store.book.shows.first(where: { $0.id == firstShow })?.totals().availableCents, 30_000)
        XCTAssertEqual(try value.store.book.shows.first(where: { $0.id == secondShow })?.totals().availableCents, 22_000)
    }

    func testKnownZeroAndEmptyListOutcomesDoNotInventCashOrRequireTradeInput() throws {
        let value = try fixture()
        try record(.purchase, in: value, totals: totals(cash: 0))
        XCTAssertEqual(try available(value), 30_000)
        try record(.tradeAndPurchase, in: value, totals: OfferTotals())
        XCTAssertEqual(value.list.outcomeRecord?.kind, .tradeAndPurchase)
        XCTAssertEqual(value.store.activeShow?.entries.count, 0)
    }

    func testPartialPricesAndMissingOrMismatchedTradeInputDoNotPostCash() throws {
        let value = try fixture(), bytes = value.disk.data
        XCTAssertThrowsError(try record(.purchase, in: value, totals: totals(unpriced: 1))) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .partialValuation)
        }
        XCTAssertThrowsError(try record(.tradeAndPurchase, in: value)) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .missingTradePrice)
        }
        let trade = try TradeTransactionCalculator.calculate(totals: totals(cash: 70, trade: 80),
            input: .init(mode: .tradeAndCash, myCardPrice: 40))
        XCTAssertThrowsError(try record(.tradeAndPurchase, in: value, transaction: trade))
        XCTAssertEqual(value.disk.data, bytes); XCTAssertNil(value.list.transactionOutcomeData)
    }

    func testSameCommittedPurchaseRemainsIdempotentAfterItsShowHasEnded() throws {
        let value = try fixture(scheduledOffset: 0)
        try record(.purchase, in: value)
        value.disk.now = value.disk.now.addingTimeInterval(3 * 86_400)
        XCTAssertNil(value.store.eligibleActiveShow)
        let writes = value.disk.writes
        try record(.purchase, in: value)
        XCTAssertEqual(value.disk.writes, writes); XCTAssertEqual(try available(value), 20_000)
        XCTAssertThrowsError(try record(.purchase, in: value, totals: totals(cash: 80))) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .noApplicableShowForReplacement)
        }
        XCTAssertEqual(try available(value), 20_000)
        try record(.nothingHappened, in: value)
        XCTAssertEqual(try available(value), 30_000, "Zero-cash correction can reverse the old auto receipt")
    }

    func testFutureShowRecordsOnlyStatusUntilAnotherExplicitActionOnItsDay() throws {
        let value = try fixture(scheduledOffset: 3 * 86_400)
        let result = try record(.purchase, in: value)
        XCTAssertNotNil(result.message); XCTAssertFalse(result.isPending)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(try available(value), 30_000); XCTAssertEqual(value.store.activeShow?.entries.count, 0)
        value.disk.now = value.disk.now.addingTimeInterval(3 * 86_400)
        try ListBudgetOutcomeService.synchronizePending(context: value.context, store: value.store)
        XCTAssertEqual(try available(value), 30_000, "Date arrival and recovery cannot initiate a cash charge")
        try record(.purchase, in: value)
        XCTAssertEqual(try available(value), 20_000)
    }

    func testMissingBudgetCanStillRecordOutcomeWithoutCreatingAHiddenShow() throws {
        let value = try fixture(show: false)
        let result = try record(.purchase, in: value)
        XCTAssertNotNil(result.message); XCTAssertTrue(value.store.book.shows.isEmpty)
        XCTAssertEqual(value.list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(value.store.book.listOutcomeUpdates?.first?.disposition, .noApplicableShow)
    }

    func testDirtyDraftAndLegacyManualReceiptArePreservedWithoutDoubleDebit() throws {
        let value = try fixture()
        value.list.name = "Unsaved name"
        XCTAssertThrowsError(try record(.purchase, in: value)) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .unsavedChanges)
        }
        value.context.rollback()
        let receipt = ShowBudgetEntry(kind: .purchase, paidCents: 5_000, recordedAt: value.disk.now,
            listID: value.list.id, listName: value.list.name)
        try value.store.record(receipt, showID: try XCTUnwrap(value.store.activeShow).id)
        let bytes = value.disk.data
        XCTAssertThrowsError(try record(.purchase, in: value)) {
            XCTAssertEqual($0 as? ListBudgetOutcomeFailure, .manualReceiptExists)
        }
        XCTAssertEqual(value.disk.data, bytes); XCTAssertNil(value.list.transactionOutcomeData)
        let result = try record(.nothingHappened, in: value)
        XCTAssertNotNil(result.message); XCTAssertEqual(try available(value), 25_000)
        XCTAssertEqual(value.store.activeShow?.entries.first?.voidedAt, nil)
    }

    func testBudgetWriteFailureCannotChangeListOutcomeOrMoney() throws {
        let value = try fixture(), before = value.store.book, bytes = value.disk.data
        value.disk.failWrites.insert(value.disk.writes + 1)
        XCTAssertThrowsError(try record(.purchase, in: value))
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.data, bytes)
        XCTAssertNil(value.list.transactionOutcomeData); XCTAssertFalse(value.context.hasChanges)
    }

    func testSwiftDataFailureKeepsDurableMoneyOnceAndRecoveryMirrorsOnlyTheOutcome() throws {
        let value = try fixture()
        let result = try record(.purchase, in: value, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertTrue(result.isPending); XCTAssertNotNil(result.message)
        XCTAssertEqual(try available(value), 20_000); XCTAssertNil(value.list.transactionOutcomeData)
        XCTAssertFalse(value.context.hasChanges)
        XCTAssertEqual(value.store.book.listOutcomeUpdates?.first?.mirrored, false)
        let recovered = try ListBudgetOutcomeService.synchronizePending(context: value.context, store: value.store)
        XCTAssertFalse(recovered.isPending); XCTAssertEqual(value.list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(try available(value), 20_000); XCTAssertEqual(value.store.activeShow?.entries.count, 1)
    }

    func testAckWriteFailureCanRetryWithoutAnotherOutcomeSaveOrAnotherCharge() throws {
        let value = try fixture()
        value.disk.failWrites.insert(value.disk.writes + 2)
        let result = try record(.purchase, in: value)
        XCTAssertTrue(result.isPending); XCTAssertEqual(value.list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(try available(value), 20_000)
        value.disk.failWrites.removeAll()
        var projectionWrites = 0
        let recovered = try ListBudgetOutcomeService.synchronizePending(context: value.context, store: value.store,
            save: { context in projectionWrites += 1; try context.save() })
        XCTAssertFalse(recovered.isPending); XCTAssertEqual(projectionWrites, 0)
        XCTAssertEqual(value.store.activeShow?.entries.count, 1)
    }

    func testPendingDeletedListIsNotRecreatedAndItsCashReceiptRemains() throws {
        let value = try fixture()
        try record(.purchase, in: value, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        value.context.delete(value.list); try value.context.save()
        let recovered = try ListBudgetOutcomeService.synchronizePending(context: value.context, store: value.store)
        XCTAssertFalse(recovered.isPending)
        XCTAssertTrue(try value.context.fetch(FetchDescriptor<CardList>()).isEmpty)
        XCTAssertEqual(try available(value), 20_000)
        XCTAssertEqual(value.store.book.listOutcomeUpdates?.first?.mirrored, true)
    }

    func testPendingBudgetAndInventorySurviveFileReopeningWithoutDoubleCharge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inventoryURL = folder.appendingPathComponent("inventory.store"), budgetURL = folder.appendingPathComponent("budget.json")
        func beforeTermination() throws {
            let container = try AppPersistence.open(url: inventoryURL), context = container.mainContext
            let list = try makeList(context: context), store = ShowBudgetStore(url: budgetURL)
            try store.create(name: "Persistent show", startingCents: 30_000)
            let result = try ListBudgetOutcomeService.record(.purchase, totals: totals(), transaction: nil,
                for: list, context: context, store: store, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            XCTAssertTrue(result.isPending)
        }
        try beforeTermination()
        let container = try AppPersistence.open(url: inventoryURL), store = ShowBudgetStore(url: budgetURL)
        let list = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertNil(list.transactionOutcomeData)
        try ListBudgetOutcomeService.synchronizePending(context: container.mainContext, store: store)
        XCTAssertEqual(list.outcomeRecord?.kind, .purchase)
        XCTAssertEqual(try XCTUnwrap(store.activeShow).totals().availableCents, 20_000)
        XCTAssertEqual(store.activeShow?.entries.count, 1)
    }

    func testVersionOneBudgetMigratesInMemoryAndNextWriteUsesVersionTwo() throws {
        let old = ShowBudgetBook(shows: [.init(name: "Old show", startingCents: 30_000)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["version"] = 1
        let disk = Disk(); disk.data = try JSONSerialization.data(withJSONObject: json)
        let bytes = disk.data
        let store = ShowBudgetStore(read: { _ in disk.data }, write: { data, _ in disk.writes += 1; disk.data = data })
        XCTAssertTrue(store.isLoaded); XCTAssertEqual(store.book.version, 2); XCTAssertEqual(disk.data, bytes)
        let id = try XCTUnwrap(store.book.shows.first).id
        try store.update(showID: id, name: "Updated old show", startingCents: 30_000)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(disk.data)) as? [String: Any])
        XCTAssertEqual(written["version"] as? Int, 2)
        XCTAssertEqual(store.book.shows.first?.startingCents, 30_000)
    }
}
