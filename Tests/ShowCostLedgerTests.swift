import XCTest
@testable import CardShowScanner

@MainActor final class ShowCostLedgerTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var fail = false
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }
    private struct Fixture {
        let disk: Disk
        let store: ShowBudgetStore
        let showID: UUID
        let stockID: UUID
    }
    private func card(_ id: String = "card", price: Decimal? = 10) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: id, printing: "Normal"),
            name: "Card " + id, set: "Cost fixtures", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"])
    }
    private func store(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { bytes, _ in
            disk.writes += 1
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = bytes
        }, now: { disk.now })
    }
    private func fixture(quantity: Int = 1, cost: Int64? = nil, price: Decimal? = 10) throws -> Fixture {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([.init(sourceInventoryID: 7, card: card("stock", price: price),
            quantity: quantity)], sourceLocationID: 9)
        let show = try ledger.create(name: "Cost show", startingCents: 30_000)
        let item = try XCTUnwrap(ledger.inventory.first)
        if let cost { try ledger.setInventoryCost(itemID: item.id, totalCostCents: cost) }
        return .init(disk: disk, store: ledger, showID: show, stockID: item.id)
    }
    private func purchase(_ cents: Int64 = 700, quantity: Int = 1,
                          price: Decimal? = 10, listID: UUID? = nil) -> ShowTransactionDraft {
        .init(kind: .purchase, incomingListID: listID,
            incomingListName: listID == nil ? nil : "Original incoming list",
            incoming: [.init(card: card("purchased", price: price), quantity: quantity)], incomingValueCents: cents)
    }
    private func sale(_ itemID: UUID, quantity: Int = 1, received: Int64 = 1_000,
                      fee: Int64 = 0) -> ShowTransactionDraft {
        .init(kind: .sale, outgoing: [.init(inventoryID: itemID, quantity: quantity)],
            saleReceivedCents: received, feeCents: fee)
    }
    private func item(_ id: UUID, in ledger: ShowBudgetStore) throws -> ShowInventoryItem {
        try XCTUnwrap(ledger.inventory.first { $0.id == id })
    }
    private func totals(_ ledger: ShowBudgetStore, showID: UUID? = nil) throws -> ShowBudgetTotals {
        try XCTUnwrap(ledger.book.shows.first { $0.id == (showID ?? ledger.book.activeShowID) }).totals()
    }
    private func legacyVersionThreeBytes(_ value: Fixture) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        object["version"] = 3
        for key in ["costAdjustments", "costLedgerBaseline", "costMutations", "legacyTransactionIDs", "legacyReversedTransactionIDs"] {
            object.removeValue(forKey: key)
        }
        var inventory = try XCTUnwrap(object["inventory"] as? [[String: Any]])
        for index in inventory.indices { inventory[index].removeValue(forKey: "remainingCostCents") }
        object["inventory"] = inventory
        var transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        for index in transactions.indices {
            transactions[index].removeValue(forKey: "accounting")
            var draft = try XCTUnwrap(transactions[index]["draft"] as? [String: Any])
            draft.removeValue(forKey: "feeCents")
            transactions[index]["draft"] = draft
        }
        object["transactions"] = transactions
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func assertRejected(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let disk = Disk(); disk.data = try JSONSerialization.data(withJSONObject: object)
        let bytes = disk.data, failed = store(disk)
        XCTAssertFalse(failed.isLoaded, file: file, line: line)
        XCTAssertThrowsError(try failed.create(name: "Replacement", startingCents: 0), file: file, line: line)
        XCTAssertEqual(disk.data, bytes, file: file, line: line)
        XCTAssertEqual(disk.writes, 0, file: file, line: line)
    }

    func testSevenDollarPurchaseAndTenDollarSaleSeparateCashFromThreeDollarProfit() throws {
        let value = try fixture()
        let bought = try value.store.recordTransaction(purchase(), showID: value.showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        XCTAssertEqual(try item(acquiredID, in: value.store).remainingCostCents, 700)
        XCTAssertEqual(try item(acquiredID, in: value.store).acquiredByTransactionID, bought.id)
        XCTAssertEqual(try totals(value.store).availableCents, 29_300)
        let sold = try value.store.recordTransaction(sale(acquiredID), showID: value.showID)
        XCTAssertEqual(sold.totalCostCents, 700)
        XCTAssertEqual(sold.profitCents, 300)
        XCTAssertEqual(sold.accounting?.outgoing.first?.proceedsCents, 1_000)
        XCTAssertEqual(sold.accounting?.outgoing.first?.profitCents, 300)
        XCTAssertEqual(sold.reinvestedCents, 650)
        XCTAssertEqual(sold.savedCents, 350)
        let cash = try totals(value.store)
        XCTAssertEqual(cash.availableCents, 29_950, "The $7 acquisition is paid once, when purchased")
        XCTAssertEqual(cash.savedCents, 350)
        XCTAssertEqual(cash.cashOnHandCents, 30_300)
        XCTAssertEqual(try item(acquiredID, in: value.store).remainingCostCents, 0)
        let summary = try value.store.profitSummary()
        XCTAssertEqual(summary.salesCents, 1_000)
        XCTAssertEqual(summary.soldCostCents, 700)
        XCTAssertEqual(summary.knownProfitCents, 300)
        XCTAssertTrue(summary.isComplete)
    }

    func testSaleFeesUseGrossSplitAndReduceBuyingFundsExactlyOnceIncludingLosses() throws {
        let value = try fixture(quantity: 2, cost: 1_400)
        let sold = try value.store.recordTransaction(sale(value.stockID, fee: 100), showID: value.showID)
        XCTAssertEqual(sold.profitCents, 200)
        XCTAssertEqual(sold.feeCents, 100)
        XCTAssertEqual(sold.accounting?.buyingFundsDeltaCents, 550)
        XCTAssertEqual(value.store.activeShow?.entries.first?.feeCents, 100)
        XCTAssertEqual(try totals(value.store).availableCents, 30_550)
        XCTAssertEqual(try totals(value.store).savedCents, 350)
        let loss = try value.store.recordTransaction(sale(value.stockID, received: 500, fee: 50), showID: value.showID)
        XCTAssertEqual(loss.profitCents, -250)
        XCTAssertEqual(loss.accounting?.outgoing.first?.profitCents, -250)
        let cash = try totals(value.store)
        XCTAssertEqual(cash.availableCents, 30_825)
        XCTAssertEqual(cash.savedCents, 525)
        XCTAssertEqual(cash.feesCents, 150)
        XCTAssertEqual(cash.cashOnHandCents, 31_350)
        XCTAssertEqual(try value.store.profitSummary().knownProfitCents, -50)
    }

    func testPartialSalesConsumeEveryCostCentAndUndoRestoresExactBasisAndCash() throws {
        let value = try fixture(quantity: 3, cost: 1_000)
        var receipts: [ShowTransactionReceipt] = []
        for fee in [1, 0, 0] as [Int64] {
            receipts.append(try value.store.recordTransaction(sale(value.stockID, received: 500, fee: fee), showID: value.showID))
        }
        XCTAssertEqual(receipts.compactMap(\.totalCostCents), [334, 333, 333])
        XCTAssertEqual(receipts.compactMap(\.profitCents).reduce(0, +), 499)
        XCTAssertEqual(try item(value.stockID, in: value.store).quantity, 0)
        XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, 0)
        let snapshots = receipts.map(\.accounting)
        for (receipt, expectedCost) in zip(receipts.reversed(), [333, 666, 1_000] as [Int64]) {
            try value.store.undoTransaction(receipt.id)
            XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, expectedCost)
        }
        XCTAssertEqual(try item(value.stockID, in: value.store).quantity, 3)
        XCTAssertEqual(try totals(value.store).availableCents, 30_000)
        XCTAssertEqual(try totals(value.store).savedCents, 0)
        XCTAssertEqual(try totals(value.store).feesCents, 0)
        XCTAssertEqual(value.store.transactions.map(\.accounting), snapshots)
        XCTAssertTrue(value.store.transactions.allSatisfy { $0.reversedAt != nil })
        XCTAssertEqual(try value.store.profitSummary().knownProfitCents, 0)
    }

    func testOutOfOrderPartialSaleUndoRestoresRecordedCostsAndReplaysActualBeforeStates() throws {
        let value = try fixture(quantity: 3, cost: 1_000)
        let first = try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        let second = try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        XCTAssertEqual(first.totalCostCents, 334); XCTAssertEqual(second.totalCostCents, 333)
        let firstMutation = try XCTUnwrap(value.store.book.costMutations.first { $0.kind == .record && $0.operationID == first.id })
        let secondMutation = try XCTUnwrap(value.store.book.costMutations.first { $0.kind == .record && $0.operationID == second.id })
        XCTAssertEqual(firstMutation.changes.first?.before?.quantity, 3)
        XCTAssertEqual(firstMutation.changes.first?.before?.remainingCostCents, 1_000)
        XCTAssertEqual(firstMutation.changes.first?.after.remainingCostCents, 666)
        XCTAssertEqual(secondMutation.changes.first?.before?.quantity, 2)
        XCTAssertEqual(secondMutation.changes.first?.before?.remainingCostCents, 666)
        XCTAssertEqual(secondMutation.changes.first?.after.remainingCostCents, 333)
        try value.store.undoTransaction(first.id)
        XCTAssertEqual(try item(value.stockID, in: value.store).quantity, 2)
        XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, 667)
        let restarted = store(value.disk)
        XCTAssertTrue(restarted.isLoaded)
        XCTAssertEqual(restarted.transactions[1].accounting, second.accounting)
        try restarted.undoTransaction(second.id)
        XCTAssertEqual(try item(value.stockID, in: restarted).quantity, 3)
        XCTAssertEqual(try item(value.stockID, in: restarted).remainingCostCents, 1_000)
        XCTAssertEqual(try totals(restarted).availableCents, 30_000)
        XCTAssertEqual(store(value.disk).book, restarted.book)
    }

    func testTradesCarryCostThroughEveryCashDirectionAndRecognizeOnlyExcessCash() throws {
        let cases: [(ShowTransactionKind, Int64, Int64, Int64, Int64, Int64)] = [
            (.trade, 5_000, 5_000, 4_000, 0, 0),
            (.tradePayCustomer, 7_000, 5_000, 6_000, 0, -2_000),
            (.tradeReceiveCash, 3_000, 5_000, 2_000, 0, 2_000),
            (.tradeReceiveCash, 1_000, 7_000, 0, 2_000, 6_000)
        ]
        for (kind, incomingValue, outgoingValue, carriedCost, profit, delta) in cases {
            let value = try fixture(cost: 4_000)
            let draft = ShowTransactionDraft(kind: kind, incoming: [.init(card: card("trade", price: 90))],
                outgoing: [.init(inventoryID: value.stockID, quantity: 1)],
                incomingValueCents: incomingValue, outgoingValueCents: outgoingValue)
            let receipt = try value.store.recordTransaction(draft, showID: value.showID)
            let acquiredID = try XCTUnwrap(receipt.incoming.first?.inventoryID)
            XCTAssertEqual(receipt.totalCostCents, 4_000)
            XCTAssertEqual(receipt.profitCents, profit)
            XCTAssertEqual(try item(acquiredID, in: value.store).remainingCostCents, carriedCost)
            XCTAssertEqual(receipt.accounting?.incoming.first?.totalCostCents, carriedCost)
            XCTAssertEqual(try totals(value.store).availableCents, 30_000 + delta)
            XCTAssertEqual(try totals(value.store).savedCents, 0)
            XCTAssertEqual(try value.store.profitSummary().tradeCashProfitCents, profit)
            try value.store.undoTransaction(receipt.id)
            XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, 4_000)
            XCTAssertEqual(try totals(value.store).availableCents, 30_000)
            XCTAssertEqual(try value.store.profitSummary().knownProfitCents, 0)
        }
        let value = try fixture(cost: 2_000)
        let even = ShowTransactionDraft(kind: .trade, incoming: [.init(card: card("even", price: 32))],
            outgoing: [.init(inventoryID: value.stockID, quantity: 1)],
            incomingValueCents: 3_200, outgoingValueCents: 3_500, makeEven: true)
        let receipt = try value.store.recordTransaction(even, showID: value.showID)
        XCTAssertEqual(receipt.concessionCents, 300)
        XCTAssertEqual(receipt.accounting?.incoming.first?.totalCostCents, 2_000)
        XCTAssertEqual(receipt.profitCents, 0)
        XCTAssertEqual(try totals(value.store).availableCents, 30_000)
    }

    func testUnknownTradeBasisStaysUnknownAcrossPaidTradeAndSaleWhileKnownZeroRemainsKnown() throws {
        let value = try fixture()
        let first = try value.store.recordTransaction(.init(kind: .tradeReceiveCash,
            incoming: [.init(card: card("first trade"))], outgoing: [.init(inventoryID: value.stockID, quantity: 1)],
            incomingValueCents: 1_000, outgoingValueCents: 7_000), showID: value.showID)
        let firstID = try XCTUnwrap(first.incoming.first?.inventoryID)
        let second = try value.store.recordTransaction(.init(kind: .tradePayCustomer,
            incoming: [.init(card: card("second trade"))], outgoing: [.init(inventoryID: firstID, quantity: 1)],
            incomingValueCents: 3_000, outgoingValueCents: 1_000), showID: value.showID)
        let secondID = try XCTUnwrap(second.incoming.first?.inventoryID)
        let sold = try value.store.recordTransaction(sale(secondID), showID: value.showID)
        for receipt in [first, second, sold] {
            XCTAssertNil(receipt.totalCostCents); XCTAssertNil(receipt.profitCents)
        }
        XCTAssertNil(try item(firstID, in: value.store).remainingCostCents)
        XCTAssertNil(try item(secondID, in: value.store).remainingCostCents)
        let summary = try value.store.profitSummary()
        XCTAssertEqual(summary.knownProfitCents, 0)
        XCTAssertEqual(summary.unknownCostQuantity, 3)
        XCTAssertEqual(summary.incompleteTransactionCount, 3)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(try totals(value.store).availableCents, 34_650)
        let zero = try fixture(cost: 0)
        let free = try zero.store.recordTransaction(.init(kind: .trade,
            incoming: [.init(card: card("zero trade"))], outgoing: [.init(inventoryID: zero.stockID, quantity: 1)],
            incomingValueCents: 1_000, outgoingValueCents: 1_000), showID: zero.showID)
        XCTAssertEqual(free.profitCents, 0)
        let freeID = try XCTUnwrap(free.incoming.first?.inventoryID)
        XCTAssertEqual(try item(freeID, in: zero.store).remainingCostCents, 0)
        XCTAssertEqual(try zero.store.recordTransaction(sale(freeID), showID: zero.showID).profitCents, 1_000)
        XCTAssertTrue(try zero.store.profitSummary().isComplete)
    }

    func testPurchaseAllocationsUseOffersNegotiatedTotalsAndReviewedOverridesWithoutMergingLots() throws {
        let value = try fixture()
        let shared = card("same card", price: 100)
        var negotiated = ShowTransactionDraft(kind: .purchase,
            incoming: [.init(card: shared, quantity: 2, costWeightCents: 600),
                       .init(card: shared, costWeightCents: 400)], incomingValueCents: 700)
        let first = try value.store.recordTransaction(negotiated, showID: value.showID)
        XCTAssertEqual(first.accounting?.incoming.compactMap(\.totalCostCents), [420, 280])
        XCTAssertEqual(first.incoming.count, 2)
        XCTAssertNotEqual(first.incoming[0].inventoryID, first.incoming[1].inventoryID)
        for (line, cost) in zip(first.incoming, [420, 280] as [Int64]) {
            XCTAssertEqual(try item(line.inventoryID, in: value.store).remainingCostCents, cost)
        }
        negotiated.id = UUID()
        negotiated.incoming[0].allocatedCostCents = 123
        let partial = try value.store.recordTransaction(negotiated, showID: value.showID)
        XCTAssertEqual(partial.accounting?.incoming.compactMap(\.totalCostCents), [123, 577])
        negotiated.id = UUID()
        negotiated.incoming[1].allocatedCostCents = 577
        let reviewed = try value.store.recordTransaction(negotiated, showID: value.showID)
        XCTAssertEqual(reviewed.accounting?.incoming.compactMap(\.totalCostCents), [123, 577])
        XCTAssertEqual(Set((first.incoming + partial.incoming + reviewed.incoming).map(\.inventoryID)).count, 6)
        XCTAssertEqual(try totals(value.store).paidCents, 2_100)
    }

    func testFeeSaleFailureRetryAndUndoAreAtomicAndIdempotent() throws {
        let value = try fixture(quantity: 2, cost: 1_000)
        let draft = sale(value.stockID, fee: 100), original = value.store.book, originalBytes = value.disk.data
        value.disk.fail = true
        XCTAssertThrowsError(try value.store.recordTransaction(draft, showID: value.showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .saveFailed)
        }
        XCTAssertEqual(value.store.book, original); XCTAssertEqual(value.disk.data, originalBytes)
        value.disk.fail = false
        let receipt = try value.store.recordTransaction(draft, showID: value.showID)
        XCTAssertEqual(receipt.totalCostCents, 500); XCTAssertEqual(receipt.profitCents, 400)
        let committed = value.store.book, committedBytes = value.disk.data, writes = value.disk.writes
        XCTAssertEqual(try value.store.recordTransaction(draft, showID: value.showID), receipt)
        XCTAssertEqual(value.disk.writes, writes)
        var changed = draft; changed.feeCents = 101
        XCTAssertThrowsError(try value.store.recordTransaction(changed, showID: value.showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .conflictingEntry)
        }
        value.disk.fail = true
        XCTAssertThrowsError(try value.store.undoTransaction(receipt.id))
        XCTAssertEqual(value.store.book, committed); XCTAssertEqual(value.disk.data, committedBytes)
        value.disk.fail = false
        try value.store.undoTransaction(receipt.id)
        XCTAssertEqual(try item(value.stockID, in: value.store).quantity, 2)
        XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, 1_000)
        XCTAssertEqual(try totals(value.store).availableCents, 30_000)
        XCTAssertEqual(try totals(value.store).feesCents, 0)
        XCTAssertEqual(try value.store.profitSummary().knownProfitCents, 0)
        let undone = value.store.book, undoWrites = value.disk.writes
        try value.store.undoTransaction(receipt.id)
        XCTAssertEqual(value.store.book, undone); XCTAssertEqual(value.disk.writes, undoWrites)
    }

    func testRemainingCostEditsAreAuditedAtomicAndNeverRewriteSoldProfit() throws {
        let value = try fixture(quantity: 2)
        let original = value.store.book, originalBytes = value.disk.data
        value.disk.fail = true
        XCTAssertThrowsError(try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: 1_000))
        XCTAssertEqual(value.store.book, original); XCTAssertEqual(value.disk.data, originalBytes)
        value.disk.fail = false
        try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: 1_000)
        let writes = value.disk.writes
        try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: 1_000)
        XCTAssertEqual(value.disk.writes, writes)
        XCTAssertEqual(value.store.book.costAdjustments.count, 1)
        XCTAssertNil(value.store.book.costAdjustments.first?.previousCostCents)
        let sold = try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        XCTAssertEqual(sold.totalCostCents, 500); XCTAssertEqual(sold.profitCents, 500)
        try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: 750)
        XCTAssertEqual(value.store.transactions.first, sold)
        let adjustment = try XCTUnwrap(value.store.book.costAdjustments.last)
        XCTAssertEqual(adjustment.quantity, 1)
        XCTAssertEqual(adjustment.previousCostCents, 500)
        XCTAssertEqual(adjustment.totalCostCents, 750)
        XCTAssertEqual(try value.store.profitSummary().knownProfitCents, 500)
        try value.store.undoTransaction(sold.id)
        XCTAssertEqual(try item(value.stockID, in: value.store).remainingCostCents, 1_250,
                       "Undo adds the recorded consumed cost to the corrected remaining copies")
        XCTAssertEqual(value.store.transactions.first?.accounting, sold.accounting)
        XCTAssertEqual(value.store.book.costAdjustments.count, 2)
        for invalid in [-1, ShowBudgetMoney.maximumCents + 1] as [Int64] {
            XCTAssertThrowsError(try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: invalid))
        }
    }

    func testUndoUnknownConsumedCostCannotInventBasisFromALaterRemainingCostEdit() throws {
        let value = try fixture(quantity: 2)
        let sold = try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        XCTAssertNil(sold.totalCostCents)
        try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: 750)
        try value.store.undoTransaction(sold.id)
        XCTAssertEqual(try item(value.stockID, in: value.store).quantity, 2)
        XCTAssertNil(try item(value.stockID, in: value.store).remainingCostCents)
        XCTAssertNil(value.store.transactions.first?.profitCents)
    }

    func testUndoRetainsDependentLotGuardAndUnrelatedAcquisitionsCannotSupplyItsBasis() throws {
        let value = try fixture()
        let first = try value.store.recordTransaction(purchase(1_000, quantity: 2), showID: value.showID)
        let second = try value.store.recordTransaction(purchase(1_200, quantity: 2), showID: value.showID)
        let firstID = try XCTUnwrap(first.incoming.first?.inventoryID), secondID = try XCTUnwrap(second.incoming.first?.inventoryID)
        let sold = try value.store.recordTransaction(sale(firstID), showID: value.showID)
        let before = value.store.book, bytes = value.disk.data
        XCTAssertThrowsError(try value.store.undoTransaction(first.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .dependentStockUsed)
        }
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.data, bytes)
        XCTAssertEqual(try item(secondID, in: value.store).remainingCostCents, 1_200)
        try value.store.undoTransaction(sold.id)
        XCTAssertEqual(try item(firstID, in: value.store).remainingCostCents, 1_000)
        try value.store.undoTransaction(first.id)
        XCTAssertEqual(try item(firstID, in: value.store).quantity, 0)
        XCTAssertEqual(try item(firstID, in: value.store).remainingCostCents, 0)
        XCTAssertEqual(try item(secondID, in: value.store).quantity, 2)
        XCTAssertEqual(try item(secondID, in: value.store).remainingCostCents, 1_200)
        XCTAssertThrowsError(try value.store.setInventoryCost(itemID: firstID, totalCostCents: 1))
    }

    func testProfitSummariesIncludeDeletedShowsAndDiscloseUnknownAndBudgetOnlySales() throws {
        let value = try fixture(quantity: 2, cost: 1_400)
        let known = try value.store.recordTransaction(sale(value.stockID, fee: 100), showID: value.showID)
        let second = try value.store.create(name: "Second show", startingCents: 10_000)
        try value.store.setInventoryCost(itemID: value.stockID, totalCostCents: nil)
        try value.store.recordTransaction(sale(value.stockID, received: 500), showID: second)
        try value.store.record(.init(kind: .sale, grossReceivedCents: 200, feeCents: 20,
            recordedAt: value.disk.now), showID: second)
        let firstSummary = try value.store.profitSummary(showID: value.showID)
        XCTAssertEqual(firstSummary.salesCents, 1_000); XCTAssertEqual(firstSummary.knownProfitCents, 200)
        XCTAssertTrue(firstSummary.isComplete)
        let summary = try value.store.profitSummary()
        XCTAssertEqual(summary.salesCents, 1_700)
        XCTAssertEqual(summary.sellingFeesCents, 120)
        XCTAssertEqual(summary.soldCostCents, 700)
        XCTAssertEqual(summary.knownProfitCents, 200)
        XCTAssertEqual(summary.unknownCostQuantity, 1)
        XCTAssertEqual(summary.unknownCostLineCount, 1)
        XCTAssertEqual(summary.incompleteTransactionCount, 1)
        XCTAssertEqual(summary.uncostedSaleCount, 1)
        XCTAssertFalse(summary.isComplete)
        try value.store.deleteShow(showID: value.showID)
        XCTAssertEqual(try value.store.profitSummary(), summary)
        XCTAssertEqual(try value.store.profitSummary(showID: value.showID), firstSummary)
        let restarted = store(value.disk)
        XCTAssertEqual(try restarted.profitSummary(), summary)
        try restarted.undoTransaction(known.id)
        XCTAssertEqual(try restarted.profitSummary().salesCents, 700)
        XCTAssertEqual(try restarted.profitSummary().knownProfitCents, 0)
        XCTAssertTrue(try restarted.profitSummary(showID: value.showID).isComplete)
    }

    func testIncompleteSaleSummaryRetainsKnownRowsWithoutClaimingCompleteProfit() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([
            .init(sourceInventoryID: 1, card: card("known"), quantity: 1),
            .init(sourceInventoryID: 2, card: card("unknown"), quantity: 1)
        ], sourceLocationID: 9)
        let show = try ledger.create(name: "Mixed sale", startingCents: 0)
        try ledger.setInventoryCost(itemID: ledger.inventory[0].id, totalCostCents: 700)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: ledger.inventory.map { .init(inventoryID: $0.id, quantity: 1) },
            saleReceivedCents: 2_000, feeCents: 200), showID: show)
        XCTAssertNil(sold.totalCostCents); XCTAssertNil(sold.profitCents)
        XCTAssertEqual(sold.accounting?.outgoing[0].profitCents, 200)
        XCTAssertNil(sold.accounting?.outgoing[1].profitCents)
        let summary = try ledger.profitSummary()
        XCTAssertEqual(summary.knownProfitCents, 200)
        XCTAssertEqual(summary.soldCostCents, 700)
        XCTAssertEqual(summary.unknownCostQuantity, 1)
        XCTAssertFalse(summary.isComplete)
    }

    func testCashOnlyReceivedPaidAndPureTradesDiscloseIncompleteProfitByShowUntilVoided() throws {
        let value = try fixture()
        let received = ShowBudgetEntry(kind: .trade, grossReceivedCents: 600,
            reinvestmentPercent: 100, recordedAt: value.disk.now)
        let paid = ShowBudgetEntry(kind: .trade, paidCents: 400, recordedAt: value.disk.now)
        let pure = ShowBudgetEntry(kind: .trade, recordedAt: value.disk.now)
        for entry in [received, paid, pure] { try value.store.record(entry, showID: value.showID) }
        let first = try value.store.profitSummary(showID: value.showID)
        XCTAssertEqual(first.uncostedTradeCount, 3)
        XCTAssertEqual(first.salesCents, 0)
        XCTAssertEqual(first.soldCostCents, 0)
        XCTAssertEqual(first.knownProfitCents, 0)
        XCTAssertEqual(first.tradeCashProfitCents, 0)
        XCTAssertEqual(first.unknownCostQuantity, 0)
        XCTAssertFalse(first.isComplete)
        let secondID = try value.store.create(name: "Other cash-only trades", startingCents: 10_000)
        let other = ShowBudgetEntry(kind: .trade, grossReceivedCents: 1_000,
            reinvestmentPercent: 100, recordedAt: value.disk.now)
        try value.store.record(other, showID: secondID)
        XCTAssertEqual(try value.store.profitSummary(showID: value.showID), first)
        XCTAssertEqual(try value.store.profitSummary(showID: secondID).uncostedTradeCount, 1)
        XCTAssertEqual(try value.store.profitSummary().uncostedTradeCount, 4)
        for (entry, count) in zip([received, paid, pure], [2, 1, 0]) {
            try value.store.void(entryID: entry.id, showID: value.showID, now: value.disk.now)
            XCTAssertEqual(try value.store.profitSummary(showID: value.showID).uncostedTradeCount, count)
        }
        XCTAssertTrue(try value.store.profitSummary(showID: value.showID).isComplete)
        XCTAssertFalse(try value.store.profitSummary().isComplete)
        XCTAssertEqual(try value.store.profitSummary().salesCents, 0)
        XCTAssertEqual(try value.store.profitSummary().knownProfitCents, 0)
        try value.store.void(entryID: other.id, showID: secondID, now: value.disk.now)
        XCTAssertEqual(try value.store.profitSummary().uncostedTradeCount, 0)
        XCTAssertTrue(try value.store.profitSummary().isComplete)
        XCTAssertEqual(try totals(value.store, showID: value.showID).availableCents, 30_000)
        XCTAssertTrue(try store(value.disk).profitSummary().isComplete)
    }

    func testOfflineActualTotalProfitPersistsWithoutQuotesAndReviewedProceedsEnableRowProfit() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([
            .init(sourceInventoryID: 1, card: card("A", price: nil), quantity: 1),
            .init(sourceInventoryID: 2, card: card("B", price: nil), quantity: 1)
        ], sourceLocationID: 9)
        let show = try ledger.create(name: "Offline show", startingCents: 0)
        for (item, cost) in zip(ledger.inventory, [300, 400] as [Int64]) {
            try ledger.setInventoryCost(itemID: item.id, totalCostCents: cost)
        }
        var draft = ShowTransactionDraft(kind: .sale,
            outgoing: ledger.inventory.map { .init(inventoryID: $0.id, quantity: 1) },
            saleReceivedCents: 1_000, feeCents: 100)
        let receipt = try ledger.recordTransaction(draft, showID: show)
        XCTAssertEqual(receipt.totalCostCents, 700); XCTAssertEqual(receipt.profitCents, 200)
        XCTAssertTrue(receipt.accounting?.outgoing.allSatisfy { $0.proceedsCents == nil && $0.profitCents == nil } == true)
        let reopened = store(disk)
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertEqual(reopened.transactions.first, receipt)
        XCTAssertEqual(try reopened.profitSummary().knownProfitCents, 200)
        XCTAssertTrue(try reopened.profitSummary().isComplete)
        try reopened.undoTransaction(receipt.id)
        draft.id = UUID()
        draft.outgoing[0].allocatedProceedsCents = 400
        draft.outgoing[1].allocatedProceedsCents = 600
        let reviewed = try reopened.recordTransaction(draft, showID: show)
        XCTAssertEqual(reviewed.accounting?.outgoing.compactMap(\.proceedsCents), [400, 600])
        XCTAssertEqual(reviewed.accounting?.outgoing.compactMap(\.feeCents), [40, 60])
        XCTAssertEqual(reviewed.accounting?.outgoing.compactMap(\.profitCents), [60, 140])
        XCTAssertEqual(reviewed.profitCents, 200)
    }

    func testVersionsOneAndTwoMigrateCashDatesAndListSnapshotsWithoutInventingProfit() throws {
        let disk = Disk(), listID = UUID()
        let entries = [ShowBudgetEntry(kind: .purchase, paidCents: 700, recordedAt: disk.now,
            listID: listID, listName: "Original list"),
            ShowBudgetEntry(kind: .sale, grossReceivedCents: 1_000, feeCents: 100, recordedAt: disk.now)]
        let original = ShowBudgetEvent(name: "Historical show", startingCents: 30_000, createdAt: disk.now,
            entries: entries, startDate: disk.now, endDate: disk.now)
        let encoded = try JSONEncoder().encode(ShowBudgetBook(shows: [original], activeShowID: original.id))
        for version in [1, 2] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["version"] = version
            object.removeValue(forKey: "inventory"); object.removeValue(forKey: "transactions")
            for key in ["costAdjustments", "costLedgerBaseline", "costMutations", "legacyTransactionIDs", "legacyReversedTransactionIDs"] {
                object.removeValue(forKey: key)
            }
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let historical = Disk(); historical.data = bytes
            let migrated = store(historical)
            XCTAssertTrue(migrated.isLoaded)
            XCTAssertEqual(migrated.book.version, 4)
            XCTAssertEqual(migrated.book.shows, [original])
            XCTAssertEqual(try totals(migrated), try original.totals())
            XCTAssertTrue(migrated.book.inventory.isEmpty)
            XCTAssertTrue(migrated.book.costAdjustments.isEmpty)
            XCTAssertEqual(try migrated.profitSummary().knownProfitCents, 0)
            XCTAssertEqual(try migrated.profitSummary().uncostedSaleCount, 1)
            XCTAssertFalse(try migrated.profitSummary().isComplete)
            XCTAssertEqual(historical.data, bytes); XCTAssertEqual(historical.writes, 0)
        }
    }

    func testVersionThreeMigrationKeepsHistoricalStockCostsAndSaleProfitUnknown() throws {
        let value = try fixture()
        let listID = UUID(), bought = try value.store.recordTransaction(purchase(700, quantity: 2, listID: listID), showID: value.showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let sold = try value.store.recordTransaction(sale(acquiredID), showID: value.showID)
        let oldCash = try totals(value.store)
        let disk = Disk(); disk.data = try legacyVersionThreeBytes(value)
        let migrated = store(disk)
        XCTAssertTrue(migrated.isLoaded)
        XCTAssertEqual(migrated.book.version, 4)
        XCTAssertEqual(try totals(migrated), oldCash)
        XCTAssertEqual(migrated.transaction(forListID: listID)?.incomingListName, "Original incoming list")
        XCTAssertEqual(migrated.transactions.map(\.id), [bought.id, sold.id])
        XCTAssertTrue(migrated.inventory.allSatisfy { $0.remainingCostCents == nil })
        XCTAssertTrue(migrated.transactions.allSatisfy { $0.accounting == nil && $0.profitCents == nil && $0.draft.feeCents == 0 })
        XCTAssertEqual(Set(migrated.book.legacyTransactionIDs), Set([bought.id, sold.id]))
        XCTAssertTrue(migrated.book.legacyReversedTransactionIDs.isEmpty)
        XCTAssertTrue(migrated.book.costLedgerBaseline.allSatisfy { $0.remainingCostCents == nil })
        XCTAssertEqual(migrated.book.costLedgerBaseline.count, migrated.inventory.count)
        XCTAssertTrue(migrated.book.costMutations.isEmpty)
        try migrated.setInventoryCost(itemID: acquiredID, totalCostCents: 700)
        XCTAssertNil(migrated.transactions.last?.profitCents)
        XCTAssertEqual(try migrated.profitSummary().knownProfitCents, 0)
        XCTAssertFalse(try migrated.profitSummary().isComplete)
        let restarted = store(disk)
        XCTAssertEqual(restarted.book, migrated.book)
        XCTAssertEqual(try restarted.profitSummary().knownProfitCents, 0)
        let newSale = try restarted.recordTransaction(sale(acquiredID, fee: 100), showID: value.showID)
        XCTAssertEqual(newSale.totalCostCents, 700); XCTAssertEqual(newSale.profitCents, 200)
        let persisted = store(disk)
        XCTAssertTrue(persisted.isLoaded)
        XCTAssertEqual(persisted.book, restarted.book)
        try persisted.undoTransaction(newSale.id)
        XCTAssertEqual(try item(acquiredID, in: persisted).remainingCostCents, 700)
        try persisted.undoTransaction(sold.id)
        XCTAssertEqual(try item(acquiredID, in: persisted).quantity, 2)
        XCTAssertNil(try item(acquiredID, in: persisted).remainingCostCents)
        try persisted.undoTransaction(bought.id)
        XCTAssertEqual(try item(acquiredID, in: persisted).quantity, 0)
        XCTAssertNil(try item(acquiredID, in: persisted).remainingCostCents)
        XCTAssertEqual(try totals(persisted).availableCents, 30_000)
        XCTAssertEqual(store(disk).book, persisted.book)
    }

    func testVersionFourRequiresJournalMetadataAndCannotLoseReceiptAccounting() throws {
        let value = try fixture(quantity: 3, cost: 1_000)
        try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        for key in ["costLedgerBaseline", "costMutations", "legacyTransactionIDs", "legacyReversedTransactionIDs"] {
            var stripped = original; stripped.removeValue(forKey: key)
            try assertRejected(stripped)
        }
        var strippedAccounting = original
        var receipts = try XCTUnwrap(strippedAccounting["transactions"] as? [[String: Any]])
        receipts[0].removeValue(forKey: "accounting")
        strippedAccounting["transactions"] = receipts
        try assertRejected(strippedAccounting)
        var strippedMutations = original; strippedMutations["costMutations"] = [] as [Any]
        try assertRejected(strippedMutations)
    }

    func testVersionThreeMigrationKeepsPreviouslyReversedReceiptsIdempotent() throws {
        let value = try fixture()
        let bought = try value.store.recordTransaction(purchase(), showID: value.showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let sold = try value.store.recordTransaction(sale(acquiredID), showID: value.showID)
        try value.store.undoTransaction(sold.id)
        let cash = try totals(value.store)
        let disk = Disk(); disk.data = try legacyVersionThreeBytes(value)
        let migrated = store(disk)
        XCTAssertTrue(migrated.isLoaded)
        XCTAssertEqual(Set(migrated.book.legacyTransactionIDs), Set([bought.id, sold.id]))
        XCTAssertEqual(migrated.book.legacyReversedTransactionIDs, [sold.id])
        XCTAssertEqual(try totals(migrated), cash)
        let before = migrated.book, writes = disk.writes
        try migrated.undoTransaction(sold.id)
        XCTAssertEqual(migrated.book, before); XCTAssertEqual(disk.writes, writes)
        try migrated.undoTransaction(bought.id)
        XCTAssertEqual(try item(acquiredID, in: migrated).quantity, 0)
        XCTAssertNil(try item(acquiredID, in: migrated).remainingCostCents)
        XCTAssertEqual(try totals(migrated).availableCents, 30_000)
        XCTAssertEqual(store(disk).book, migrated.book)
    }

    func testJournalRejectsPlausibleInventoryBasisChangesAndMissingOrMismatchedAdjustments() throws {
        let value = try fixture(quantity: 3, cost: 1_000)
        try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        var changedBasis = original
        var inventory = try XCTUnwrap(changedBasis["inventory"] as? [[String: Any]])
        inventory[0]["remainingCostCents"] = 665
        changedBasis["inventory"] = inventory
        try assertRejected(changedBasis)
        var omittedAdjustments = original; omittedAdjustments.removeValue(forKey: "costAdjustments")
        try assertRejected(omittedAdjustments)
        var mismatchedAdjustment = original
        var adjustments = try XCTUnwrap(mismatchedAdjustment["costAdjustments"] as? [[String: Any]])
        adjustments[0]["quantity"] = 2
        mismatchedAdjustment["costAdjustments"] = adjustments
        try assertRejected(mismatchedAdjustment)
        var changedBaseline = original
        var baseline = try XCTUnwrap(changedBaseline["costLedgerBaseline"] as? [[String: Any]])
        baseline[0]["quantity"] = 4
        changedBaseline["costLedgerBaseline"] = baseline
        try assertRejected(changedBaseline)
    }

    func testJournalRejectsChangedConsumedCostEvenWhenReceiptProfitAndAfterBasisAgree() throws {
        let value = try fixture(quantity: 3, cost: 1_000)
        let sold = try value.store.recordTransaction(sale(value.stockID), showID: value.showID)
        XCTAssertEqual(sold.totalCostCents, 334)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        var receipts = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        var accounting = try XCTUnwrap(receipts[0]["accounting"] as? [String: Any])
        accounting["totalCostCents"] = 335; accounting["profitCents"] = 665
        var outgoing = try XCTUnwrap(accounting["outgoing"] as? [[String: Any]])
        outgoing[0]["totalCostCents"] = 335; outgoing[0]["profitCents"] = 665
        accounting["outgoing"] = outgoing
        receipts[0]["accounting"] = accounting; object["transactions"] = receipts
        var inventory = try XCTUnwrap(object["inventory"] as? [[String: Any]])
        inventory[0]["remainingCostCents"] = 665; object["inventory"] = inventory
        var mutations = try XCTUnwrap(object["costMutations"] as? [[String: Any]])
        let index = try XCTUnwrap(mutations.firstIndex { $0["kind"] as? String == "record" })
        var changes = try XCTUnwrap(mutations[index]["changes"] as? [[String: Any]])
        var after = try XCTUnwrap(changes[0]["after"] as? [String: Any])
        after["remainingCostCents"] = 665; changes[0]["after"] = after
        mutations[index]["changes"] = changes; object["costMutations"] = mutations
        try assertRejected(object)
    }

    func testCorruptRecordedProfitAndInvalidRemainingCostsCannotOverwriteLedger() throws {
        let value = try fixture(cost: 700)
        try value.store.recordTransaction(sale(value.stockID, fee: 100), showID: value.showID)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        var badProfit = original
        var receipts = try XCTUnwrap(badProfit["transactions"] as? [[String: Any]])
        var accounting = try XCTUnwrap(receipts[0]["accounting"] as? [String: Any])
        accounting["profitCents"] = 999
        receipts[0]["accounting"] = accounting; badProfit["transactions"] = receipts
        var badCost = original
        var inventory = try XCTUnwrap(badCost["inventory"] as? [[String: Any]])
        inventory[0]["remainingCostCents"] = 1
        badCost["inventory"] = inventory
        for corrupted in [badProfit, badCost] {
            let disk = Disk(); disk.data = try JSONSerialization.data(withJSONObject: corrupted)
            let bytes = disk.data, failed = store(disk)
            XCTAssertFalse(failed.isLoaded)
            XCTAssertThrowsError(try failed.create(name: "Replacement", startingCents: 0))
            XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, 0)
        }
    }
}
