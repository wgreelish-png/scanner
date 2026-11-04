import XCTest
@testable import CardShowScanner

@MainActor final class ShowTransactionsTests: XCTestCase {
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
    private func card(_ id: String = "incoming", price: Decimal = 35) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: id, printing: "Normal"),
            name: "Card " + id, set: "Fixture", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"])
    }
    private func store(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { data, _ in
            disk.writes += 1
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = data
        }, now: { disk.now })
    }
    private func fixture(quantity: Int = 3, scheduled: Bool = false) throws -> Fixture {
        let disk = Disk(), value = store(disk)
        try value.seedInventory([.init(sourceInventoryID: 7, card: card("stock", price: 30), quantity: quantity)], sourceLocationID: 9)
        let day = scheduled ? disk.now : nil
        let showID = try value.create(name: "Saturday show", startingCents: 30_000, startDate: day, endDate: day)
        return .init(disk: disk, store: value, showID: showID, stockID: try XCTUnwrap(value.inventory.first?.id))
    }
    private func trade(_ kind: ShowTransactionKind = .tradePayCustomer, stock: UUID = UUID(),
                       incoming: Int64 = 3_500, outgoing: Int64 = 500, listID: UUID? = nil,
                       even: Bool = false) -> ShowTransactionDraft {
        .init(kind: kind, incomingListID: listID, incomingListName: listID == nil ? nil : "Incoming list",
            incoming: [.init(card: card())], outgoing: [.init(inventoryID: stock, quantity: 1)],
            incomingValueCents: incoming, outgoingValueCents: outgoing, makeEven: even)
    }
    private func purchase(listID: UUID? = nil, quantity: Int = 1) -> ShowTransactionDraft {
        .init(kind: .purchase, incomingListID: listID, incomingListName: listID == nil ? nil : "Incoming list",
            incoming: [.init(card: card(), quantity: quantity)], incomingValueCents: 3_500)
    }
    private func sale(stock: UUID, quantity: Int = 1, received: Int64 = 20_000) -> ShowTransactionDraft {
        .init(kind: .sale, outgoing: [.init(inventoryID: stock, quantity: quantity)],
            outgoingValueCents: 3_000, saleReceivedCents: received)
    }
    private func outcome(_ kind: ListOutcomeKind?, listID: UUID, paid: Int64 = 0,
                         received: Int64 = 0, date: Date) throws -> ListBudgetOutcomeRequest {
        .init(listID: listID, listName: "Incoming list", kind: kind, paidCents: paid,
            receivedCents: received, recordedAt: date,
            desiredOutcomeData: try kind.map { try JSONEncoder().encode(ListOutcomeRecord(kind: $0, recordedAt: date)) })
    }

    func testCheckoutCashInputRequiresAnExplicitWholeDollarAmount() {
        XCTAssertEqual(ShowTransactionCashInput.parseWholeDollars("0"), 0)
        XCTAssertEqual(ShowTransactionCashInput.parseWholeDollars(" 12\n"), 1_200)
        XCTAssertEqual(ShowTransactionCashInput.parseWholeDollars("999999999"), 99_999_999_900)
        for invalid in ["", " ", "12.00", "12.5", ".50", "12.", "-12", "+12", "$12", "1,200", "1e2", "1000000000"] {
            XCTAssertNil(ShowTransactionCashInput.parseWholeDollars(invalid), invalid)
        }
        XCTAssertEqual(ShowTransactionCashInput.input(1_200), "12")
        XCTAssertEqual(ShowTransactionCashInput.input(0), "0")
        XCTAssertEqual(ShowTransactionCashInput.input(1_249), "", "Fractional references must not become a silently truncated cash payment")
    }

    func testCalculatedCashOfferRoundsTheCompleteTotalOnceAndGuardsTheLimit() {
        let totals = OfferCalculator.calculate([.init(price: Decimal(string: "12.20"), quantity: 3)], rates: .init())
        XCTAssertEqual(totals.cash, Decimal(string: "25.62"))
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(2_562), 2_600)
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(1_249), 1_200)
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(1_250), 1_300)
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(0), 0)
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(99_999_999_949), 99_999_999_900)
        for invalid in [-1, ShowBudgetMoney.maximumCents, Int64.max] {
            XCTAssertNil(ShowTransactionCashInput.nearestWholeDollarCents(invalid))
        }
        XCTAssertEqual(totals.cash, Decimal(string: "25.62"), "Presenting a cash suggestion does not change the precise offer snapshot")
    }

    func testCashDisplayOmitsWholeDollarCentsAndShowsBuyingFundsDirection() {
        let separator = Locale.current.decimalSeparator ?? "."
        XCTAssertFalse(ShowTransactionCashInput.money(1_200).contains(separator + "00"))
        XCTAssertTrue(ShowTransactionCashInput.money(1_234).contains(separator + "34"), "Existing fractional cash remains visible")
        XCTAssertTrue(ShowTransactionCashInput.signedMoney(1_200).hasPrefix("+"))
        XCTAssertTrue(ShowTransactionCashInput.signedMoney(-1_200).hasPrefix("-"))
        XCTAssertEqual(ShowTransactionCashInput.signedMoney(0), ShowTransactionCashInput.money(0))
        XCTAssertTrue(ShowTransactionCashInput.signedMoney(-1_234).contains(separator + "34"))
    }

    func testWholeDollarCheckoutDoesNotRoundHistoricalReceiptOrCostAccounting() throws {
        let value = try fixture()
        let receipt = try value.store.recordTransaction(sale(stock: value.stockID, received: 1_249), showID: value.showID)
        XCTAssertEqual(receipt.receivedCents, 1_249)
        XCTAssertEqual(ShowBudgetMoney.parse("12.49"), 1_249)
        XCTAssertEqual(store(value.disk).transactions.first?.receivedCents, 1_249)
        XCTAssertEqual(receipt.reinvestedCents + receipt.savedCents, 1_249)
        XCTAssertEqual(ShowTransactionCashInput.nearestWholeDollarCents(receipt.receivedCents), 1_200)
        XCTAssertEqual(value.store.transactions.first?.receivedCents, 1_249)
    }

    func testCashMathUsesAgreedValuesAndSeparatesSaleSavingsFromTradeCash() throws {
        let pay = try ShowTransactionMath.calculate(trade())
        XCTAssertEqual(pay, .init(paidCents: 3_000, receivedCents: 0, reinvestedCents: 0, savedCents: 0, concessionCents: 0))
        let receive = try ShowTransactionMath.calculate(trade(.tradeReceiveCash, incoming: 500, outgoing: 3_000))
        XCTAssertEqual(receive, .init(paidCents: 0, receivedCents: 2_500, reinvestedCents: 2_500, savedCents: 0, concessionCents: 0))
        XCTAssertEqual(try ShowTransactionMath.calculate(purchase()).paidCents, 3_500)
        let sold = try ShowTransactionMath.calculate(sale(stock: UUID(), received: 20_001))
        XCTAssertEqual(sold.receivedCents, 20_001)
        XCTAssertEqual(sold.reinvestedCents, 13_001)
        XCTAssertEqual(sold.savedCents, 7_000)
        XCTAssertEqual(sold.reinvestedCents + sold.savedCents, sold.receivedCents)
        let equal = try ShowTransactionMath.calculate(trade(.trade, incoming: 3_500, outgoing: 3_500))
        XCTAssertEqual(equal.paidCents, 0); XCTAssertEqual(equal.receivedCents, 0)
    }

    func testMakeEvenRecordsSignedConcessionWithoutChangingCardMarketOrCash() throws {
        let draft = trade(.trade, incoming: 3_200, outgoing: 3_500, even: true)
        let result = try ShowTransactionMath.calculate(draft)
        XCTAssertEqual(result.concessionCents, 300)
        XCTAssertEqual(result.paidCents, 0); XCTAssertEqual(result.receivedCents, 0)
        XCTAssertEqual(draft.incoming[0].card.marketPrice, 35)
        let opposite = try ShowTransactionMath.calculate(trade(.trade, incoming: 3_500, outgoing: 3_200, even: true))
        XCTAssertEqual(opposite.concessionCents, -300)
    }

    func testWrongDirectionMissingCardsDuplicateRowsAndInvalidAmountsFailBeforeRecording() throws {
        var invalid = [trade(.trade), trade(.tradePayCustomer, incoming: 500, outgoing: 3_000),
                       trade(.tradeReceiveCash, incoming: 3_500, outgoing: 500),
                       trade(.tradePayCustomer, even: true)]
        var row = purchase(); row.incoming = []; invalid.append(row)
        row = purchase(); row.outgoing = [.init(inventoryID: UUID(), quantity: 1)]; invalid.append(row)
        row = sale(stock: UUID()); row.incoming = [.init(card: card())]; invalid.append(row)
        row = purchase(); row.incoming[0].quantity = 0; invalid.append(row)
        row = purchase(); row.incoming.append(row.incoming[0]); invalid.append(row)
        row = sale(stock: UUID()); row.outgoing.append(row.outgoing[0]); invalid.append(row)
        row = purchase(); row.incomingValueCents = -1; invalid.append(row)
        row = purchase(); row.incomingValueCents = ShowBudgetMoney.maximumCents + 1; invalid.append(row)
        row = purchase(); row.incoming[0].quantity = ShowBudgetBook.maximumQuantity + 1; invalid.append(row)
        for draft in invalid {
            XCTAssertThrowsError(try ShowTransactionMath.calculate(draft)) {
                XCTAssertEqual($0 as? ShowTransactionFailure, .invalidDraft)
            }
        }
    }

    func testCashAndStockPostTogetherAndSurviveRelaunchWithReceiptSnapshots() throws {
        let value = try fixture()
        let sold = try value.store.recordTransaction(sale(stock: value.stockID), showID: value.showID)
        let pay = try value.store.recordTransaction(trade(stock: value.stockID), showID: value.showID)
        let receive = try value.store.recordTransaction(trade(.tradeReceiveCash, stock: value.stockID,
            incoming: 500, outgoing: 3_000), showID: value.showID)
        let totals = try XCTUnwrap(value.store.activeShow).totals()
        XCTAssertEqual(totals.availableCents, 42_500); XCTAssertEqual(totals.savedCents, 7_000)
        XCTAssertEqual(totals.paidCents, 3_000); XCTAssertEqual(totals.grossReceivedCents, 22_500)
        XCTAssertEqual(value.store.inventory.first?.quantity, 0)
        XCTAssertEqual(value.store.inventory.filter { $0.acquiredByTransactionID != nil }.count, 2)
        XCTAssertEqual(pay.incoming.first?.card.marketPrice, 35)
        XCTAssertEqual(receive.reinvestedCents, 2_500); XCTAssertEqual(receive.savedCents, 0)
        try value.store.update(showID: value.showID, name: "Renamed show", startingCents: 30_000)
        let restarted = store(value.disk)
        XCTAssertTrue(restarted.isLoaded)
        XCTAssertEqual(restarted.book, value.store.book)
        XCTAssertEqual(restarted.transactions, [sold, pay, receive])
        XCTAssertEqual(restarted.transactions.first?.showName, "Saturday show")
        XCTAssertEqual(try XCTUnwrap(restarted.activeShow).totals(), totals)
    }

    func testNegotiatedSaleAllocationsSurviveRelaunchUsingOriginalMarketSnapshots() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([
            .init(sourceInventoryID: 1, card: card("A", price: 100), quantity: 1),
            .init(sourceInventoryID: 2, card: card("B", price: 25), quantity: 2)
        ], sourceLocationID: 9)
        let showID = try ledger.create(name: "Synthetic show", startingCents: 30_000)
        let draft = ShowTransactionDraft(kind: .sale,
            outgoing: ledger.inventory.map { .init(inventoryID: $0.id, quantity: $0.quantity) },
            saleReceivedCents: 12_000)
        let receipt = try ledger.recordTransaction(draft, showID: showID)
        let before = try XCTUnwrap(ShowSaleMath.allocations(receipt.outgoing, receivedCents: receipt.receivedCents))
        XCTAssertEqual(ShowSaleMath.marketPercentage(receipt.outgoing, receivedCents: receipt.receivedCents), 80)
        XCTAssertEqual(before.map(\.receivedCents).sorted(), [4_000, 8_000])
        let restarted = store(disk)
        let saved = try XCTUnwrap(restarted.transactions.first)
        XCTAssertEqual(ShowSaleMath.allocations(saved.outgoing, receivedCents: saved.receivedCents), before)
        XCTAssertEqual(saved.outgoing.map { $0.card.marketPrice }.compactMap { $0 }.sorted(), [25, 100])
        XCTAssertEqual(try XCTUnwrap(restarted.activeShow).totals().availableCents, 37_800)
        XCTAssertEqual(try XCTUnwrap(restarted.activeShow).totals().savedCents, 4_200)
        try restarted.undoTransaction(saved.id)
        XCTAssertEqual(restarted.inventory.reduce(0) { $0 + $1.quantity }, 3)
        XCTAssertEqual(try XCTUnwrap(restarted.activeShow).totals().availableCents, 30_000)
    }

    func testFailedWriterPublishesNoPartialRecordUndoOrDeletionAndRetriesWork() throws {
        let value = try fixture(), draft = purchase()
        let original = value.store.book, originalBytes = value.disk.data
        value.disk.fail = true
        XCTAssertThrowsError(try value.store.recordTransaction(draft, showID: value.showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .saveFailed)
        }
        XCTAssertEqual(value.store.book, original); XCTAssertEqual(value.disk.data, originalBytes)
        value.disk.fail = false
        let receipt = try value.store.recordTransaction(draft, showID: value.showID)
        let committed = value.store.book, committedBytes = value.disk.data
        value.disk.fail = true
        XCTAssertThrowsError(try value.store.undoTransaction(receipt.id))
        XCTAssertEqual(value.store.book, committed); XCTAssertEqual(value.disk.data, committedBytes)
        XCTAssertThrowsError(try value.store.deleteShow(showID: value.showID))
        XCTAssertEqual(value.store.book, committed); XCTAssertEqual(value.disk.data, committedBytes)
        value.disk.fail = false
        try value.store.undoTransaction(receipt.id)
        XCTAssertNotNil(value.store.transactions.first?.reversedAt)
        XCTAssertEqual(try XCTUnwrap(value.store.activeShow).totals().availableCents, 30_000)
        XCTAssertFalse(value.store.isSaving)
    }

    func testExactRetryIsIdempotentAfterDatesAndDeletionButChangedIDReuseFails() throws {
        let value = try fixture(scheduled: true), draft = sale(stock: UUID())
        var actual = draft; actual.outgoing[0].inventoryID = value.stockID
        let receipt = try value.store.recordTransaction(actual, showID: value.showID)
        value.disk.now = value.disk.now.addingTimeInterval(3 * 86_400)
        XCTAssertThrowsError(try value.store.recordTransaction(sale(stock: value.stockID), showID: value.showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .outsideShowDates)
        }
        try value.store.deleteShow(showID: value.showID)
        let writes = value.disk.writes, bytes = value.disk.data
        XCTAssertEqual(try value.store.recordTransaction(actual, showID: value.showID), receipt)
        XCTAssertEqual(value.disk.writes, writes); XCTAssertEqual(value.disk.data, bytes)
        actual.note = "Changed confirmation"
        XCTAssertThrowsError(try value.store.recordTransaction(actual, showID: value.showID)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .conflictingEntry)
        }
        XCTAssertEqual(value.store.transactions.count, 1)
    }

    func testInventorySeedsOnceKeepsSoldOutLotAndRejectsAnotherSourceLocation() throws {
        let value = try fixture(quantity: 1)
        try value.store.recordTransaction(sale(stock: value.stockID), showID: value.showID)
        let before = value.store.book, writes = value.disk.writes
        try value.store.seedInventory([.init(sourceInventoryID: 7, card: card("new remote quote"), quantity: 50)], sourceLocationID: 9)
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.writes, writes)
        XCTAssertEqual(value.store.inventory.first?.quantity, 0)
        XCTAssertEqual(value.store.inventory.first?.card.name, "Card stock")
        XCTAssertThrowsError(try value.store.seedInventory([], sourceLocationID: 10)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryLocationConflict)
        }
        XCTAssertThrowsError(try value.store.recordTransaction(sale(stock: value.stockID), showID: value.showID)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .insufficientStock)
        }
        XCTAssertEqual(value.store.book, before)
    }

    func testDeletingShowRetainsInventoryAndReceiptsAndUndoWorksAfterRelaunch() throws {
        let value = try fixture(scheduled: true), listID = UUID()
        let receipt = try value.store.recordTransaction(trade(stock: value.stockID, listID: listID), showID: value.showID)
        value.disk.now = value.disk.now.addingTimeInterval(10 * 86_400)
        try value.store.deleteShow(showID: value.showID)
        let currentStock = value.store.inventory
        XCTAssertTrue(value.store.visibleShows.isEmpty); XCTAssertNil(value.store.activeShow)
        XCTAssertEqual(value.store.transactions, [receipt]); XCTAssertEqual(value.store.inventory, currentStock)
        let restarted = store(value.disk)
        XCTAssertTrue(restarted.isLoaded); XCTAssertTrue(restarted.visibleShows.isEmpty)
        XCTAssertEqual(restarted.transactions, [receipt]); XCTAssertEqual(restarted.inventory, currentStock)
        try restarted.undoTransaction(receipt.id)
        XCTAssertEqual(restarted.inventory.first?.quantity, 3)
        XCTAssertEqual(restarted.inventory.last?.quantity, 0)
        XCTAssertNil(restarted.transaction(forListID: listID))
        XCTAssertNotNil(restarted.transactions.first?.reversedAt)
        XCTAssertEqual(try XCTUnwrap(restarted.book.shows.first).totals().availableCents, 30_000)
        let writes = value.disk.writes, reversed = restarted.book
        try restarted.undoTransaction(receipt.id); try restarted.deleteShow(showID: value.showID)
        XCTAssertEqual(restarted.book, reversed); XCTAssertEqual(value.disk.writes, writes)
    }

    func testUndoTracksAcquiredLotIdentityAndRequiresLaterSaleToBeUndoneFirst() throws {
        let value = try fixture()
        let first = try value.store.recordTransaction(purchase(quantity: 2), showID: value.showID)
        let second = try value.store.recordTransaction(purchase(quantity: 2), showID: value.showID)
        let acquiredID = try XCTUnwrap(first.incoming.first?.inventoryID)
        let sold = try value.store.recordTransaction(sale(stock: acquiredID), showID: value.showID)
        let before = value.store.book, writes = value.disk.writes
        XCTAssertThrowsError(try value.store.undoTransaction(first.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .dependentStockUsed)
        }
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.writes, writes)
        XCTAssertEqual(value.store.inventory.first { $0.id == second.incoming.first?.inventoryID }?.quantity, 2,
            "Unrelated copies cannot replace the acquired lot's sold copy")
        try value.store.undoTransaction(sold.id)
        try value.store.undoTransaction(first.id)
        XCTAssertEqual(value.store.inventory.first { $0.id == acquiredID }?.quantity, 0)
        XCTAssertEqual(value.store.inventory.first { $0.id == second.incoming.first?.inventoryID }?.quantity, 2)
        XCTAssertEqual(try XCTUnwrap(value.store.activeShow).totals().availableCents, 26_500)
    }

    func testIncomingListCanHaveOnlyOneActiveTransactionAndIsReusableAfterUndo() throws {
        let value = try fixture(), listID = UUID(), draft = purchase(listID: UUID())
        var firstDraft = draft; firstDraft.incomingListID = listID
        let receipt = try value.store.recordTransaction(firstDraft, showID: value.showID)
        let before = value.store.book, writes = value.disk.writes
        XCTAssertThrowsError(try value.store.recordTransaction(purchase(listID: listID), showID: value.showID)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .incomingListAlreadyUsed)
        }
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.writes, writes)
        try value.store.undoTransaction(receipt.id)
        let replacement = try value.store.recordTransaction(purchase(listID: listID), showID: value.showID)
        XCTAssertEqual(value.store.transaction(forListID: listID)?.id, replacement.id)
        XCTAssertEqual(value.store.transactions.count, 2)
    }

    func testLegacyCashAndZeroCashTradeOutcomeBlockNewTransaction() throws {
        let cashValue = try fixture(), cashList = UUID()
        try cashValue.store.record(.init(kind: .purchase, paidCents: 1_000,
            recordedAt: cashValue.disk.now, listID: cashList, listName: "Incoming list"), showID: cashValue.showID)
        let cashBefore = cashValue.store.book
        XCTAssertThrowsError(try cashValue.store.recordTransaction(purchase(listID: cashList), showID: cashValue.showID)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .legacyListOutcomeExists)
        }
        XCTAssertEqual(cashValue.store.book, cashBefore)
        let tradeValue = try fixture(), tradeList = UUID()
        _ = try tradeValue.store.applyListOutcome(outcome(.trade, listID: tradeList, date: tradeValue.disk.now))
        let tradeBefore = tradeValue.store.book
        XCTAssertThrowsError(try tradeValue.store.recordTransaction(purchase(listID: tradeList), showID: tradeValue.showID)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .legacyListOutcomeExists)
        }
        XCTAssertEqual(tradeValue.store.book, tradeBefore)
    }

    func testActiveTransactionRejectsLegacyOutcomeAndIndividualCashVoid() throws {
        let value = try fixture(), listID = UUID()
        let receipt = try value.store.recordTransaction(purchase(listID: listID), showID: value.showID)
        let before = value.store.book, writes = value.disk.writes
        let kinds: [ListOutcomeKind?] = [.purchase, .trade, .nothingHappened, nil]
        for kind in kinds {
            let request = try outcome(kind, listID: listID, paid: kind == .purchase ? 3_500 : 0, date: value.disk.now)
            XCTAssertThrowsError(try value.store.applyListOutcome(request)) {
                XCTAssertEqual($0 as? ShowTransactionFailure, .incomingListAlreadyUsed)
            }
        }
        XCTAssertThrowsError(try value.store.void(entryID: receipt.id, showID: value.showID, now: value.disk.now)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryLinkedEntry)
        }
        XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.writes, writes)
    }

    func testFullTenThousandRowMirrorStillAllowsPurchasesAndTradesAndKeepsSoldOutLots() throws {
        let disk = Disk(), value = store(disk), mirroredCard = card("mirrored", price: 5)
        let seeds = (0..<ShowBudgetBook.maximumInventorySeeds).map {
            ShowInventorySeed(sourceInventoryID: $0 + 1, card: mirroredCard, quantity: 1)
        }
        try value.seedInventory(seeds, sourceLocationID: 9)
        let sourceLot = try XCTUnwrap(value.inventory.first)
        let showID = try value.create(name: "Full inventory show", startingCents: 30_000)
        let bought = try value.recordTransaction(purchase(), showID: showID)
        let exchanged = try value.recordTransaction(trade(stock: sourceLot.id), showID: showID)
        XCTAssertEqual(value.inventory.count, ShowBudgetBook.maximumInventorySeeds + 2)
        XCTAssertEqual(value.inventory.filter { $0.sourceInventoryID != nil }.count, ShowBudgetBook.maximumInventorySeeds)
        XCTAssertEqual(value.inventory.first { $0.id == sourceLot.id }?.quantity, 0)
        XCTAssertEqual(value.inventory.first { $0.id == bought.incoming.first?.inventoryID }?.quantity, 1)
        XCTAssertEqual(value.inventory.first { $0.id == exchanged.incoming.first?.inventoryID }?.quantity, 1)
        let before = value.book, writes = disk.writes
        try value.seedInventory(seeds, sourceLocationID: 9)
        XCTAssertEqual(value.book, before); XCTAssertEqual(disk.writes, writes)
        let restarted = store(disk)
        XCTAssertTrue(restarted.isLoaded)
        XCTAssertEqual(restarted.inventory.count, ShowBudgetBook.maximumInventorySeeds + 2)
        XCTAssertEqual(restarted.inventory.first { $0.id == sourceLot.id }?.quantity, 0)
        XCTAssertEqual(restarted.transactions, [bought, exchanged])
    }

    func testDeletingAtVisibleShowCapacityAllowsReplacementWhileRetainingTombstone() throws {
        let disk = Disk()
        let shows = (0..<ShowBudgetBook.maximumShows).map {
            ShowBudgetEvent(name: "Show \($0)", startingCents: 30_000, createdAt: disk.now)
        }
        let deletedID = try XCTUnwrap(shows.first?.id)
        disk.data = try JSONEncoder().encode(ShowBudgetBook(shows: shows, activeShowID: deletedID))
        let value = store(disk), before = value.book, bytes = disk.data
        XCTAssertThrowsError(try value.create(name: "Beyond capacity", startingCents: 0)) {
            XCTAssertEqual($0 as? ShowBudgetFailure, .capacityExceeded)
        }
        XCTAssertEqual(value.book, before); XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, 0)
        try value.deleteShow(showID: deletedID)
        let replacement = try value.create(name: "Replacement show", startingCents: 50_000)
        XCTAssertEqual(value.visibleShows.count, ShowBudgetBook.maximumShows)
        XCTAssertEqual(value.book.shows.count, ShowBudgetBook.maximumShows + 1)
        XCTAssertNotNil(value.book.shows.first { $0.id == deletedID }?.deletedAt)
        XCTAssertFalse(value.visibleShows.contains { $0.id == deletedID })
        XCTAssertEqual(value.activeShow?.id, replacement)
        let restarted = store(disk)
        XCTAssertTrue(restarted.isLoaded); XCTAssertEqual(restarted.book, value.book)
    }

    func testOversizedImportAndDraftCardCountsFailWithCapacityErrorWithoutWriting() throws {
        let importDisk = Disk(), importStore = store(importDisk), sharedCard = card()
        let tooManySeeds = (0...ShowBudgetBook.maximumInventorySeeds).map {
            ShowInventorySeed(sourceInventoryID: $0 + 1, card: sharedCard, quantity: 1)
        }
        XCTAssertThrowsError(try importStore.seedInventory(tooManySeeds, sourceLocationID: 9)) {
            XCTAssertEqual($0 as? ShowBudgetFailure, .capacityExceeded)
        }
        XCTAssertTrue(importStore.inventory.isEmpty); XCTAssertNil(importStore.inventorySourceLocationID)
        XCTAssertNil(importDisk.data); XCTAssertEqual(importDisk.writes, 0)
        let value = try fixture(), before = value.store.book, bytes = value.disk.data, writes = value.disk.writes
        var oversizedPurchase = purchase()
        oversizedPurchase.incoming = (0...ShowBudgetBook.maximumTransactionCards).map { _ in
            ShowIncomingCard(card: sharedCard)
        }
        var oversizedSale = sale(stock: value.stockID)
        oversizedSale.outgoing = (0...ShowBudgetBook.maximumTransactionCards).map { _ in
            ShowTransactionSelection(inventoryID: UUID(), quantity: 1)
        }
        for draft in [oversizedPurchase, oversizedSale] {
            XCTAssertThrowsError(try value.store.recordTransaction(draft, showID: value.showID)) {
                XCTAssertEqual($0 as? ShowBudgetFailure, .capacityExceeded)
            }
            XCTAssertEqual(value.store.book, before); XCTAssertEqual(value.disk.data, bytes)
            XCTAssertEqual(value.disk.writes, writes)
        }
    }

    func testCorruptCashProjectionOrAcquiredQuantityCannotLoadAndOverwriteLedger() throws {
        let value = try fixture()
        try value.store.recordTransaction(purchase(), showID: value.showID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.disk.data)) as? [String: Any])
        var badStock = object
        var stock = try XCTUnwrap(badStock["inventory"] as? [[String: Any]])
        stock[stock.count - 1]["quantity"] = 2
        badStock["inventory"] = stock
        var badCash = object
        var shows = try XCTUnwrap(badCash["shows"] as? [[String: Any]])
        var entries = try XCTUnwrap(shows[0]["entries"] as? [[String: Any]])
        entries[0]["paidCents"] = 1
        shows[0]["entries"] = entries; badCash["shows"] = shows
        for corrupted in [badStock, badCash] {
            let disk = Disk(); disk.data = try JSONSerialization.data(withJSONObject: corrupted)
            let bytes = disk.data, failed = store(disk)
            XCTAssertFalse(failed.isLoaded)
            XCTAssertThrowsError(try failed.create(name: "Replacement", startingCents: 0))
            XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, 0)
        }
    }
}
