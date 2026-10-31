import XCTest
@testable import CardShowScanner

final class ShowBudgetTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_793_270_400)

    private func show(_ entries: [ShowBudgetEntry] = [], starting: Int64 = 30_000) -> ShowBudgetEvent {
        ShowBudgetEvent(name: "Saturday show", startingCents: starting, createdAt: instant, entries: entries)
    }

    private func entry(_ kind: ShowBudgetEntryKind, paid: Int64 = 0, received: Int64 = 0,
                       fees: Int64 = 0, percent: Int = 65,
                       basis: ShowBudgetSplitBasis = .grossProceeds) -> ShowBudgetEntry {
        ShowBudgetEntry(kind: kind, paidCents: paid, grossReceivedCents: received, feeCents: fees,
                        reinvestmentPercent: percent, splitBasis: basis, recordedAt: instant)
    }

    func testLegacyVersionOneShowWithoutDateFieldsKeepsOriginalReceiptsAndBalances() throws {
        let original = show([entry(.sale, received: 20_000, fees: 1_000)])
        let book = ShowBudgetBook(shows: [original], activeShowID: original.id)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        var shows = try XCTUnwrap(body["shows"] as? [[String: Any]])
        shows[0].removeValue(forKey: "startDate"); shows[0].removeValue(forKey: "endDate")
        body["shows"] = shows
        let reopened = try JSONDecoder().decode(ShowBudgetBook.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(reopened.version, 1)
        let restored = try XCTUnwrap(reopened.shows.first)
        XCTAssertNil(restored.startDate); XCTAssertNil(restored.endDate)
        XCTAssertEqual(restored.createdAt, original.createdAt); XCTAssertEqual(restored.entries, original.entries)
        XCTAssertEqual(try restored.totals(), try original.totals())
    }

    func testShowDateRangeValidatesWithoutChangingCashAllocation() throws {
        let baseline = show([entry(.sale, received: 20_000, fees: 1_000)])
        var dated = baseline
        dated.startDate = instant; dated.endDate = instant.addingTimeInterval(86_400)
        XCTAssertEqual(try dated.totals(), try baseline.totals())
        dated.endDate = instant
        XCTAssertNoThrow(try dated.validate(), "A one-day show is valid")
        for (start, end) in [(Optional(instant), Optional(instant.addingTimeInterval(-1))),
                             (Optional(instant), nil), (nil, Optional(instant))] {
            dated.startDate = start; dated.endDate = end
            XCTAssertThrowsError(try dated.validate()) { XCTAssertEqual($0 as? ShowBudgetFailure, .invalidDates) }
        }
        dated.startDate = Date(timeIntervalSince1970: .infinity); dated.endDate = instant
        XCTAssertThrowsError(try dated.validate()) { XCTAssertEqual($0 as? ShowBudgetFailure, .invalidDates) }
    }

    func testThreeHundredBudgetAndTwoHundredSaleAddsOneHundredThirtyAndSavesSeventy() throws {
        let result = try show([entry(.sale, received: 20_000)]).totals()
        XCTAssertEqual(result.startingCents, 30_000)
        XCTAssertEqual(result.reinvestedCents, 13_000)
        XCTAssertEqual(result.savedCents, 7_000)
        XCTAssertEqual(result.availableCents, 43_000)
        XCTAssertEqual(result.cashOnHandCents, 50_000)
        XCTAssertEqual(result.availableCents + result.savedCents, result.cashOnHandCents)
    }

    func testPurchasesReduceBuyingFundsWithoutSpendingPersonalSavings() throws {
        let result = try show([entry(.sale, received: 20_000), entry(.purchase, paid: 10_000)]).totals()
        XCTAssertEqual(result.paidCents, 10_000)
        XCTAssertEqual(result.availableCents, 33_000)
        XCTAssertEqual(result.savedCents, 7_000)
        XCTAssertEqual(result.cashOnHandCents, 40_000)
    }

    func testGrossSplitPreservesSixtyFivePercentAllocationAndDeductsFeesAsCashCost() throws {
        let result = try show([entry(.sale, received: 20_000, fees: 1_000)]).totals()
        XCTAssertEqual(result.grossReceivedCents, 20_000)
        XCTAssertEqual(result.feesCents, 1_000)
        XCTAssertEqual(result.reinvestedCents, 13_000)
        XCTAssertEqual(result.savedCents, 7_000)
        XCTAssertEqual(result.availableCents, 42_000)
        XCTAssertEqual(result.cashOnHandCents, 49_000)
    }

    func testNetSplitCanBeReadWithoutChargingItsFeeTwice() throws {
        let result = try show([entry(.sale, received: 20_000, fees: 1_000, basis: .netProceeds)]).totals()
        XCTAssertEqual(result.reinvestedCents, 12_350)
        XCTAssertEqual(result.savedCents, 6_650)
        XCTAssertEqual(result.availableCents, 42_350)
        XCTAssertEqual(result.cashOnHandCents, 49_000)
        XCTAssertEqual(result.availableCents + result.savedCents, result.cashOnHandCents)
    }

    func testMixedHistoricalSplitPoliciesKeepCashIdentity() throws {
        let result = try show([entry(.sale, received: 20_000, fees: 1_000),
                               entry(.sale, received: 20_000, fees: 1_000, basis: .netProceeds)]).totals()
        XCTAssertEqual(result.reinvestedCents, 25_350)
        XCTAssertEqual(result.savedCents, 13_650)
        XCTAssertEqual(result.availableCents, 54_350)
        XCTAssertEqual(result.cashOnHandCents, 68_000)
        XCTAssertEqual(result.availableCents + result.savedCents, result.cashOnHandCents)
    }

    func testTradesUseOnlyActualCashAndPureTradeDoesNotInflateCashBudget() throws {
        let pure = try show([entry(.trade)]).totals()
        XCTAssertEqual(pure.availableCents, 30_000)
        XCTAssertEqual(pure.savedCents, 0)
        let incoming = try show([entry(.trade, received: 10_000, fees: 200)]).totals()
        XCTAssertEqual(incoming.reinvestedCents, 6_500)
        XCTAssertEqual(incoming.savedCents, 3_500)
        XCTAssertEqual(incoming.availableCents, 36_300)
        let outgoing = try show([entry(.trade, paid: 5_000)]).totals()
        XCTAssertEqual(outgoing.availableCents, 25_000)
        XCTAssertEqual(outgoing.savedCents, 0)
    }

    func testCentRoundingIsPerTransactionAndAlwaysConservesEveryCent() throws {
        let rows = [1, 2, 3, 10, 99, 101].map { entry(.sale, received: Int64($0)) }
        for row in rows {
            let split = try row.allocation()
            XCTAssertEqual(split.reinvestedCents + split.savedCents, row.grossReceivedCents)
        }
        XCTAssertEqual(try entry(.sale, received: 1).allocation().reinvestedCents, 1)
        XCTAssertEqual(try entry(.sale, received: 2).allocation().reinvestedCents, 1)
        XCTAssertEqual(try entry(.sale, received: 10).allocation().reinvestedCents, 7)
        let result = try show(rows).totals()
        XCTAssertEqual(result.availableCents + result.savedCents, result.cashOnHandCents)
    }

    func testZeroProceedsAndOneHundredPercentFeesNeverInventSpendableMoney() throws {
        XCTAssertEqual(try show([entry(.sale)]).totals().availableCents, 30_000)
        let gross = try show([entry(.sale, received: 100, fees: 100)], starting: 0).totals()
        XCTAssertEqual(gross.availableCents, -35)
        XCTAssertEqual(gross.savedCents, 35)
        XCTAssertEqual(gross.cashOnHandCents, 0)
        let net = try show([entry(.sale, received: 100, fees: 100, basis: .netProceeds)], starting: 0).totals()
        XCTAssertEqual(net.availableCents, 0)
        XCTAssertEqual(net.savedCents, 0)
    }

    func testOverspendingRemainsNegativeInsteadOfBeingClampedOrTakingFromSavings() throws {
        let result = try show([entry(.sale, received: 20_000), entry(.purchase, paid: 50_000)]).totals()
        XCTAssertEqual(result.availableCents, -7_000)
        XCTAssertEqual(result.savedCents, 7_000)
        XCTAssertEqual(result.cashOnHandCents, 0)
    }

    func testVoidingKeepsOriginalRecordButRemovesItsCashEffect() throws {
        var sale = entry(.sale, received: 20_000, fees: 1_000)
        sale.voidedAt = instant.addingTimeInterval(1)
        let event = show([sale, entry(.purchase, paid: 5_000)])
        let result = try event.totals()
        XCTAssertEqual(event.entries[0].grossReceivedCents, 20_000)
        XCTAssertEqual(result.availableCents, 25_000)
        XCTAssertEqual(result.grossReceivedCents, 0)
        XCTAssertEqual(result.feesCents, 0)
        XCTAssertEqual(result.savedCents, 0)
        XCTAssertEqual(try sale.allocation(), ShowBudgetAllocation(reinvestedCents: 0, savedCents: 0, availableDeltaCents: 0))
    }

    func testEntryPercentagesAreSnapshotsAndShowPercentageEditsCannotRewritePastSales() throws {
        var event = show([entry(.sale, received: 20_000), entry(.sale, received: 10_000, percent: 50)])
        event.reinvestmentPercent = 20
        let result = try event.totals()
        XCTAssertEqual(result.reinvestedCents, 18_000)
        XCTAssertEqual(result.savedCents, 12_000)
        XCTAssertEqual(result.availableCents, 48_000)
    }

    func testPercentBoundariesAndMaximumValidAmountsRemainExactWithoutOverflow() throws {
        XCTAssertEqual(try entry(.sale, received: 100, percent: 0).allocation().savedCents, 100)
        XCTAssertEqual(try entry(.sale, received: 100, percent: 100).allocation().reinvestedCents, 100)
        let maximum = ShowBudgetMoney.maximumCents
        let result = try show([entry(.sale, received: maximum), entry(.purchase, paid: maximum)], starting: maximum).totals()
        XCTAssertEqual(result.availableCents + result.savedCents, maximum)
        XCTAssertEqual(result.cashOnHandCents, maximum)
    }

    func testInputParsingRejectsEstimatedFractionsAndUnsupportedFormats() {
        XCTAssertEqual(ShowBudgetMoney.parse("300"), 30_000)
        XCTAssertEqual(ShowBudgetMoney.parse(" 200.5\n"), 20_050)
        XCTAssertEqual(ShowBudgetMoney.parse("85."), 8_500)
        XCTAssertEqual(ShowBudgetMoney.parse("0"), 0)
        XCTAssertEqual(ShowBudgetMoney.parse("999999999.99"), ShowBudgetMoney.maximumCents)
        XCTAssertEqual(ShowBudgetMoney.decimal(-130), Decimal(string: "-1.30"))
        for text in ["", "-1", "+1", ".50", "1.001", "1e3", "NaN", "inf", "$200", "1,000", "1000000000", "1.2.3"] {
            XCTAssertNil(ShowBudgetMoney.parse(text), text)
        }
    }

    func testContradictoryAmountsAndInvalidDatesAreRejectedEvenWhenVoided() throws {
        let rows = [entry(.purchase, received: 1), entry(.purchase, fees: 1), entry(.sale, paid: 1),
                    entry(.trade, paid: 1, received: 1), entry(.trade, fees: 1), entry(.sale, received: 1, fees: 2),
                    entry(.sale, received: -1), entry(.purchase, paid: ShowBudgetMoney.maximumCents + 1),
                    entry(.sale, received: 100, percent: -1), entry(.sale, received: 100, percent: 101)]
        for row in rows { XCTAssertThrowsError(try row.validate()) }
        var invalid = entry(.sale)
        invalid.recordedAt = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try invalid.validate())
        invalid = entry(.sale); invalid.voidedAt = instant.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalid.validate())
        invalid = entry(.purchase, received: 1); invalid.voidedAt = instant
        XCTAssertThrowsError(try invalid.allocation())
    }

    func testDuplicateShowsAndEntriesAcrossShowsCannotDoubleCountCash() throws {
        let sale = entry(.sale, received: 10_000), first = show([entry(.sale, received: 20_000)])
        XCTAssertThrowsError(try ShowBudgetBook(shows: [first, first]).validate())
        XCTAssertThrowsError(try show([sale, sale]).validate())
        XCTAssertThrowsError(try ShowBudgetBook(shows: [show([sale]), show([sale])]).validate())
    }

    func testBookRetainsSeparateShowsAndLinkedListSnapshotOnRoundTrip() throws {
        var linked = entry(.purchase, paid: 10_000)
        linked.listID = UUID(); linked.listName = "Purchased cards"; linked.note = "Cash agreed at table"
        let first = show([linked]), second = show([entry(.sale, received: 20_000)], starting: 50_000)
        let book = ShowBudgetBook(shows: [first, second], activeShowID: second.id)
        let result = try JSONDecoder().decode(ShowBudgetBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(result, book)
        XCTAssertEqual(try result.shows[0].totals().availableCents, 20_000)
        XCTAssertEqual(try result.shows[1].totals().availableCents, 63_000)
        XCTAssertEqual(result.shows[0].entries[0].listID, linked.listID)
        XCTAssertEqual(result.shows[0].entries[0].listName, linked.listName)
    }

    func testUnknownFormatSplitAndInvalidStoredCashAreRejectedOnDecode() throws {
        let event = show([entry(.sale, received: 10_000)])
        let data = try JSONEncoder().encode(ShowBudgetBook(shows: [event], activeShowID: event.id))
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var version = initial; version["version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(ShowBudgetBook.self, from: JSONSerialization.data(withJSONObject: version)))
        for (key, value) in [("splitBasis", "estimated" as Any), ("kind", "unknown" as Any), ("paidCents", -1 as Any)] {
            var object = initial
            var shows = try XCTUnwrap(object["shows"] as? [[String: Any]])
            var entries = try XCTUnwrap(shows[0]["entries"] as? [[String: Any]])
            entries[0][key] = value; shows[0]["entries"] = entries; object["shows"] = shows
            XCTAssertThrowsError(try JSONDecoder().decode(ShowBudgetBook.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testBookAndEventBoundsRejectInvalidStateRatherThanTruncateHistory() throws {
        XCTAssertThrowsError(try ShowBudgetBook(activeShowID: UUID()).validate())
        XCTAssertThrowsError(try ShowBudgetBook(version: 2).validate())
        XCTAssertThrowsError(try ShowBudgetEvent(name: "  ", startingCents: 0).validate())
        XCTAssertThrowsError(try ShowBudgetEvent(name: "Valid", startingCents: -1).validate())
        XCTAssertThrowsError(try ShowBudgetEvent(name: "Valid", startingCents: 0, reinvestmentPercent: 101).validate())
        let tooManyShows = (0...ShowBudgetBook.maximumShows).map { _ in show() }
        XCTAssertThrowsError(try ShowBudgetBook(shows: tooManyShows).validate())
        let tooManyEntries = (0...ShowBudgetBook.maximumEntriesPerShow).map { _ in entry(.trade) }
        XCTAssertThrowsError(try show(tooManyEntries).totals())
        var invalid = show(); invalid.createdAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try invalid.validate())
    }
}
