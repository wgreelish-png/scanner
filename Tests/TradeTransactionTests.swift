import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class TradeTransactionTests: XCTestCase {
    private let standard = OfferTotals(quantity: 1, market: 20, cash: 15, trade: 16, maximum: 15)
    private func amount(_ text: String) -> Decimal { Decimal(string: text)! }

    func testCustomerPaysTheUncoveredSellingPrice() async throws {
        let totals = OfferTotals(quantity: 1, market: amount("5.38"), cash: amount("4.03"), trade: amount("4.30"), maximum: 4)
        let result = try TradeTransactionCalculator.calculate(totals: totals,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10))
        XCTAssertEqual(result.outcome, .customerPays)
        XCTAssertEqual(result.tradeApplied, amount("4.30"))
        XCTAssertEqual(result.customerPays, amount("5.70"))
        XCTAssertEqual(result.finalAmount, amount("5.70"))
        XCTAssertEqual(result.remainingTradeCredit, 0); XCTAssertEqual(result.cashPayout, 0)
    }

    func testExactCreditIsAnEvenTradeWithNoCashMovement() async throws {
        for mode in [TradeTransactionMode.tradeAndCash, .tradeCreditOnly] {
            let result = try TradeTransactionCalculator.calculate(totals: standard,
                input: TradeTransactionInput(mode: mode, myCardPrice: 16))
            XCTAssertEqual(result.outcome, .evenTrade); XCTAssertEqual(result.finalAmount, 0)
            XCTAssertEqual(result.tradeApplied, 16); XCTAssertEqual(result.remainingTradeCredit, 0)
            XCTAssertEqual(result.customerPays, 0); XCTAssertEqual(result.cashPayout, 0)
        }
    }

    func testUnusedTradeIsConvertedToUnderlyingMarketBeforeCashRounding() async throws {
        let result = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10))
        XCTAssertEqual(result.outcome, .payCustomer)
        XCTAssertEqual(result.tradeApplied, 10); XCTAssertEqual(result.remainingTradeCredit, 6)
        XCTAssertEqual(result.remainingMarketValue, amount("7.50"))
        XCTAssertEqual(result.cashPayout, amount("5.63")); XCTAssertEqual(result.finalAmount, amount("5.63"))
        XCTAssertEqual(result.customerPays, 0)
        XCTAssertNotEqual(result.cashPayout, amount("4.50"), "The cash rate must not be applied to already-discounted trade credit")
    }

    func testCashOnlyKeepsCalculatedAndNegotiatedWholeListOffers() async throws {
        let input = TradeTransactionInput(mode: .cashOnly)
        let calculated = try TradeTransactionCalculator.calculate(totals: standard, input: input)
        XCTAssertEqual(calculated.outcome, .cashOffer); XCTAssertEqual(calculated.finalAmount, 15)
        XCTAssertEqual(calculated.cashPayout, 15); XCTAssertEqual(calculated.tradeApplied, 0)
        let custom = try TradeTransactionCalculator.calculate(totals: standard, input: input, customCashOffer: 25)
        XCTAssertEqual(custom.finalAmount, 25)
        let free = try TradeTransactionCalculator.calculate(totals: standard, input: input, customCashOffer: 0)
        XCTAssertEqual(free.finalAmount, 0)
        let mixed = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10), customCashOffer: 25)
        XCTAssertEqual(mixed.finalAmount, amount("9.38"), "The negotiated full-list cash value also determines the remaining payout")
        XCTAssertEqual(mixed.cashValuation, 25)
    }

    func testNegotiatedCashUpdatesTheRemainingPayoutAndClearingRestoresCalculatedCash() async throws {
        let input = TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10)
        let negotiated = try TradeTransactionCalculator.calculate(totals: standard, input: input, customCashOffer: 16)
        XCTAssertEqual(negotiated.tradeApplied, 10); XCTAssertEqual(negotiated.remainingTradeCredit, 6)
        XCTAssertEqual(negotiated.remainingMarketValue, amount("7.50"))
        XCTAssertEqual(negotiated.cashPayout, 6); XCTAssertEqual(negotiated.finalAmount, 6)
        XCTAssertEqual(negotiated.cashValuation, 16)

        let zero = try TradeTransactionCalculator.calculate(totals: standard, input: input, customCashOffer: 0)
        XCTAssertEqual(zero.cashValuation, 0); XCTAssertEqual(zero.cashPayout, 0)
        XCTAssertEqual(zero.tradeApplied, 10); XCTAssertEqual(zero.remainingTradeCredit, 6)

        let reset = try TradeTransactionCalculator.calculate(totals: standard, input: input, customCashOffer: nil)
        XCTAssertEqual(reset.cashValuation, 15)
        XCTAssertEqual(reset.cashPayout, amount("5.63")); XCTAssertEqual(reset.finalAmount, amount("5.63"))

        let creditOnly = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeCreditOnly, myCardPrice: 10), customCashOffer: 25)
        XCTAssertEqual(creditOnly.cashValuation, 25)
        XCTAssertEqual(creditOnly.cashPayout, 0); XCTAssertEqual(creditOnly.finalAmount, 6)
        let customerOwes = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 20), customCashOffer: 25)
        XCTAssertEqual(customerOwes.customerPays, 4); XCTAssertEqual(customerOwes.cashPayout, 0)
    }

    func testEffectivePercentagesUseSelectedValuesAndRequireCompletePositiveMarket() async {
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: standard.trade, market: standard.market), 80)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: standard.cash, market: standard.market), 75)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: 16, market: 20), 80)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: 25, market: 20), 125)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: 0, market: 20), 0)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: 1, market: 3), amount("33.33"))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: 10, market: 0))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: 10, market: -1))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: -1, market: 20))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: .nan, market: 20))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: 10, market: .nan))
        XCTAssertNil(TradeTransactionCalculator.effectivePercentage(valuation: 16, market: 20, unpricedQuantity: 1))
    }

    func testTradeCreditOnlyShowsUnusedCreditWithoutPayingOrStoringIt() async throws {
        let result = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeCreditOnly, myCardPrice: 10))
        XCTAssertEqual(result.outcome, .unusedCredit); XCTAssertEqual(result.finalAmount, 6)
        XCTAssertEqual(result.remainingTradeCredit, 6); XCTAssertEqual(result.remainingMarketValue, amount("7.50"))
        XCTAssertEqual(result.cashPayout, 0); XCTAssertEqual(result.customerPays, 0)
        let noCardYet = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeCreditOnly))
        XCTAssertEqual(noCardYet.remainingTradeCredit, 16); XCTAssertEqual(noCardYet.tradeApplied, 0)
        XCTAssertEqual(noCardYet.cashPayout, 0)
    }

    func testCombinedQuantitiesAndPerCardOverridesUseTheirActualOffers() async throws {
        let rates = OfferRates(cash: 75, trade: 80, maximum: 75)
        let combined = OfferCalculator.calculate([OfferLine(price: 10, quantity: 2), OfferLine(price: 5, quantity: 1)], rates: rates)
        let result = try TradeTransactionCalculator.calculate(totals: combined,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10))
        XCTAssertEqual(combined.market, 25); XCTAssertEqual(combined.trade, 20)
        XCTAssertEqual(result.remainingMarketValue, amount("12.50")); XCTAssertEqual(result.cashPayout, amount("9.38"))

        let overridden = OfferCalculator.calculate([
            OfferLine(price: 10, quantity: 1, cashOverride: 4, tradeOverride: 5),
            OfferLine(price: 10, quantity: 1, cashOverride: 8, tradeOverride: 10)
        ], rates: rates)
        let allocation = try TradeTransactionCalculator.calculate(totals: overridden,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 5))
        XCTAssertEqual(overridden.cash, 12); XCTAssertEqual(overridden.trade, 15)
        XCTAssertEqual(allocation.remainingTradeCredit, 10)
        XCTAssertEqual(allocation.remainingMarketValue, amount("13.33")); XCTAssertEqual(allocation.cashPayout, 8)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: overridden.cash, market: overridden.market), 60)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: overridden.trade, market: overridden.market), 75)
        let negotiated = try TradeTransactionCalculator.calculate(totals: overridden,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 5), customCashOffer: 9)
        XCTAssertEqual(negotiated.remainingTradeCredit, 10); XCTAssertEqual(negotiated.cashPayout, 6)
    }

    func testZeroRatesZeroPricesAndUnpricedCardsRemainDistinct() async throws {
        let rates = OfferRates(cash: 75, trade: 0, maximum: 0)
        let noTrade = OfferCalculator.calculate([OfferLine(price: 20, quantity: 1)], rates: rates)
        let result = try TradeTransactionCalculator.calculate(totals: noTrade,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10))
        XCTAssertEqual(result.customerPays, 10); XCTAssertEqual(result.cashPayout, 0)
        XCTAssertEqual(result.tradeApplied, 0); XCTAssertEqual(result.remainingMarketValue, 0)
        let empty = try TradeTransactionCalculator.calculate(totals: OfferTotals(), input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 0))
        XCTAssertEqual(empty.outcome, .evenTrade); XCTAssertEqual(empty.finalAmount, 0); XCTAssertFalse(empty.isPartial)
        let knownZero = OfferCalculator.calculate([OfferLine(price: 0, quantity: 1)], rates: OfferRates())
        XCTAssertFalse(try TradeTransactionCalculator.calculate(totals: knownZero, input: TradeTransactionInput()).isPartial)
        let partial = OfferCalculator.calculate([OfferLine(price: 0, quantity: 1), OfferLine(price: nil, quantity: 2)], rates: OfferRates())
        let partialResult = try TradeTransactionCalculator.calculate(totals: partial, input: TradeTransactionInput())
        XCTAssertEqual(partial.quantity, 3); XCTAssertEqual(partial.unpricedQuantity, 2)
        XCTAssertTrue(partialResult.isPartial); XCTAssertEqual(partialResult.finalAmount, 0)
    }

    func testInvalidPricesTotalsAndMissingRequiredPriceAreRejected() async throws {
        for price in [Decimal(-1), .nan, amount("0.001"), CustomOfferAmount.maximum + 1] {
            XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: standard,
                input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: price)))
        }
        XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: standard, input: TradeTransactionInput(mode: .tradeAndCash))) { error in
            XCTAssertEqual(error as? TradeTransactionFailure, .missingPrice)
        }
        for badCash in [Decimal(-1), .nan, amount("0.001")] {
            XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: standard, input: TradeTransactionInput(), customCashOffer: badCash))
        }
        var invalid = standard; invalid.market = .nan
        XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: invalid, input: TradeTransactionInput()))
        invalid = standard; invalid.trade = -1
        XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: invalid, input: TradeTransactionInput()))
        invalid = standard; invalid.unpricedQuantity = 2
        XCTAssertThrowsError(try TradeTransactionCalculator.calculate(totals: invalid, input: TradeTransactionInput()))
        let largest = try TradeTransactionCalculator.calculate(totals: OfferTotals(),
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: CustomOfferAmount.maximum))
        XCTAssertEqual(largest.customerPays, CustomOfferAmount.maximum)
    }

    func testLegacySnapshotsDecodeWithoutTransactionAndNewResultsRoundTrip() async throws {
        let old = OfferSnapshot(rates: OfferRates(), totals: standard, lines: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "tradeTransaction")
        let legacy = try JSONDecoder().decode(OfferSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.tradeTransaction)
        let result = try TradeTransactionCalculator.calculate(totals: standard,
            input: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10), customCashOffer: 25)
        let snapshot = OfferSnapshot(rates: OfferRates(cash: 75, trade: 80, maximum: 75), totals: standard,
            lines: [], customCashOffer: 25, tradeTransaction: result)
        let reopened = try JSONDecoder().decode(OfferSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(reopened.tradeTransaction, result); XCTAssertEqual(reopened.customCashOffer, 25)
    }

    func testLegacyMixedEstimateKeepsItsOriginalPayoutAndCashPercentage() async throws {
        // This is the old calculation, when a custom cash-only amount did not
        // change the mixed payout. No cashValuation field existed in that JSON.
        let historicalJSON = Data("""
        {"input":{"mode":"tradeAndCash","myCardPrice":10},"tradeApplied":10,
         "remainingTradeCredit":6,"remainingMarketValue":7.5,"cashPayout":5.63,
         "customerPays":0,"outcome":"payCustomer","finalAmount":5.63,"isPartial":false}
        """.utf8)
        let historical = try JSONDecoder().decode(TradeTransactionResult.self, from: historicalJSON)
        XCTAssertNil(historical.cashValuation)
        let snapshot = OfferSnapshot(rates: OfferRates(cash: 75, trade: 80, maximum: 75), totals: standard,
            lines: [], customCashOffer: 25, tradeTransaction: historical)
        let reopened = try JSONDecoder().decode(OfferSnapshot.self, from: JSONEncoder().encode(snapshot))
        let savedResult = try XCTUnwrap(reopened.tradeTransaction)
        XCTAssertEqual(savedResult.cashPayout, amount("5.63"))
        XCTAssertEqual(savedResult.finalAmount, amount("5.63"))
        let originalCash = savedResult.resolvedCashValuation(totals: reopened.totals, customCashOffer: reopened.customCashOffer)
        XCTAssertEqual(originalCash, 15)
        XCTAssertEqual(TradeTransactionCalculator.effectivePercentage(valuation: originalCash, market: reopened.totals.market), 75)

        let current = try TradeTransactionCalculator.calculate(totals: standard,
            input: historical.input, customCashOffer: 25)
        XCTAssertEqual(current.cashValuation, 25); XCTAssertEqual(current.cashPayout, amount("9.38"))
        XCTAssertEqual(current.resolvedCashValuation(totals: standard, customCashOffer: 25), 25)
        XCTAssertEqual(savedResult.finalAmount, amount("5.63"), "Recalculating a new estimate must not mutate history")

        let legacyCashOnly = try JSONDecoder().decode(TradeTransactionResult.self, from: Data("""
        {"input":{"mode":"cashOnly"},"tradeApplied":0,"remainingTradeCredit":0,
         "remainingMarketValue":20,"cashPayout":25,"customerPays":0,
         "outcome":"cashOffer","finalAmount":25,"isPartial":false}
        """.utf8))
        XCTAssertEqual(legacyCashOnly.resolvedCashValuation(totals: standard, customCashOffer: 25), 25)
    }

    func testSavedTransactionSurvivesDiskReopeningAndLaterPriceRateEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("trade.store"))
        let schema = Schema([CardList.self, InventoryCard.self, ScanSession.self])
        func write() throws {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let session = try SessionService.start(game: "Pokémon", context: context)
            session.setRates(OfferRates(cash: 75, trade: 80, maximum: 75))
            let list = try XCTUnwrap(SessionService.list(for: session, context: context))
            var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]; card.marketPrice = 20
            try SessionService.add(card, session: session, list: list, context: context)
            try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 25,
                transactionInput: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: 10))
            session.setRates(OfferRates(cash: 10, trade: 10, maximum: 10))
            card.marketPrice = 100
            try list.cards[0].update(card); try context.save()
        }
        try write()
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<ScanSession>()).first)
        let saved = try XCTUnwrap(session.savedOffers().first)
        XCTAssertEqual(saved.totals.market, 20); XCTAssertEqual(saved.rates.cash, 75)
        XCTAssertEqual(saved.tradeTransaction?.input.myCardPrice, 10)
        XCTAssertEqual(saved.tradeTransaction?.outcome, .payCustomer)
        XCTAssertEqual(saved.tradeTransaction?.finalAmount, amount("9.38"))
        XCTAssertEqual(saved.tradeTransaction?.cashValuation, 25)
        XCTAssertEqual(saved.lines.first?.price, 20); XCTAssertEqual(saved.customCashOffer, 25)
        XCTAssertEqual(session.rates.cash, 10)
    }

    func testInvalidTransactionCannotAppendOrChangeAnEarlierSavedEstimate() async throws {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        try SessionService.saveOffer(session, list: list, context: context,
            transactionInput: TradeTransactionInput(mode: .cashOnly))
        let before = session.savedOffersData
        XCTAssertThrowsError(try SessionService.saveOffer(session, list: list, context: context,
            transactionInput: TradeTransactionInput(mode: .tradeAndCash, myCardPrice: -1)))
        XCTAssertEqual(session.savedOffersData, before)
        XCTAssertEqual(try session.savedOffers().count, 1)
    }
}
