import Foundation

enum TradeTransactionMode: String, Codable, CaseIterable, Identifiable {
    case cashOnly, tradeAndCash, tradeCreditOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cashOnly: return "Cash Only"
        case .tradeAndCash: return "Trade + Cash"
        case .tradeCreditOnly: return "Trade Credit Only"
        }
    }
}

struct TradeTransactionInput: Codable, Equatable {
    var mode: TradeTransactionMode = .cashOnly
    var myCardPrice: Decimal? = nil
}

enum TradeTransactionOutcome: String, Codable {
    case customerPays, evenTrade, payCustomer, unusedCredit, cashOffer
}

/// An immutable estimate; this does not record a payment or store future credit.
struct TradeTransactionResult: Codable, Equatable {
    var input: TradeTransactionInput
    var tradeApplied: Decimal
    var remainingTradeCredit: Decimal
    var remainingMarketValue: Decimal
    var cashPayout: Decimal
    var customerPays: Decimal
    var outcome: TradeTransactionOutcome
    var finalAmount: Decimal
    var isPartial: Bool
    // The whole-list cash value used by this estimate, before allocating the
    // unused trade fraction. Nil preserves the calculation rules of old JSON.
    var cashValuation: Decimal? = nil
    var mode: TradeTransactionMode { input.mode }
    var myCardPrice: Decimal? { input.myCardPrice }

    func resolvedCashValuation(totals: OfferTotals, customCashOffer: Decimal?) -> Decimal {
        if let cashValuation { return cashValuation }
        // Before cashValuation was stored, negotiated totals applied only to
        // cash-only offers. Never reinterpret a saved mixed transaction.
        return mode == .cashOnly ? (customCashOffer ?? totals.cash) : totals.cash
    }
}

enum TradeTransactionFailure: LocalizedError, Equatable {
    case invalidTotals, invalidPrice, missingPrice, invalidCustomCash
    var errorDescription: String? {
        switch self {
        case .invalidTotals: return "The calculated offers contain an invalid amount. Review the card values and overrides."
        case .invalidPrice: return "Enter My Card Price from $0 to $999,999,999.99 with at most two decimal places."
        case .missingPrice: return "Enter My Card Price to calculate the trade, or choose Cash Only."
        case .invalidCustomCash: return "Enter a valid custom cash offer, or use calculated cash."
        }
    }
}

enum TradeTransactionCalculator {
    /// Existing totals include quantities, configured percentages and per-card
    /// overrides. Allocate unused credit proportionally across those totals:
    /// (unused trade / total trade) × selected whole-list cash value. A negotiated
    /// cash amount updates both a cash-only offer and the remaining cash payout.
    static func calculate(totals: OfferTotals, input: TradeTransactionInput,
                          customCashOffer: Decimal? = nil) throws -> TradeTransactionResult {
        guard totals.quantity >= 0, totals.unpricedQuantity >= 0,
              totals.unpricedQuantity <= totals.quantity,
              [totals.market, totals.trade, totals.cash, totals.maximum].allSatisfy({ !$0.isNaN && $0 >= 0 }) else {
            throw TradeTransactionFailure.invalidTotals
        }
        if let price = input.myCardPrice, !CustomOfferAmount.isValid(price) { throw TradeTransactionFailure.invalidPrice }
        if let cash = customCashOffer, !CustomOfferAmount.isValid(cash) { throw TradeTransactionFailure.invalidCustomCash }
        let partial = totals.unpricedQuantity > 0
        let cashValuation = customCashOffer ?? totals.cash
        if input.mode == .cashOnly {
            let cash = OfferCalculator.cents(cashValuation)
            return TradeTransactionResult(input: input, tradeApplied: 0, remainingTradeCredit: 0,
                remainingMarketValue: OfferCalculator.cents(totals.market), cashPayout: cash, customerPays: 0,
                outcome: .cashOffer, finalAmount: cash, isPartial: partial, cashValuation: cashValuation)
        }
        if input.mode == .tradeAndCash && input.myCardPrice == nil { throw TradeTransactionFailure.missingPrice }
        let price = input.myCardPrice ?? 0
        let tradeApplied = min(price, totals.trade)
        let remainingTrade = max(0, totals.trade - tradeApplied)
        let customerPays = max(0, price - tradeApplied)
        // Zero credit cannot be converted back into a market amount. In that
        // case no credit is applied and the customer pays the full selling price.
        let unusedFraction = totals.trade > 0 ? remainingTrade / totals.trade : 0
        let marketRemainder = totals.market * unusedFraction
        let payout = input.mode == .tradeAndCash ? cashValuation * unusedFraction : 0
        guard [unusedFraction, marketRemainder, payout].allSatisfy({ !$0.isNaN && $0 >= 0 }) else {
            throw TradeTransactionFailure.invalidTotals
        }
        let outcome: TradeTransactionOutcome
        let amount: Decimal
        if customerPays > 0 { outcome = .customerPays; amount = customerPays }
        else if remainingTrade == 0 { outcome = .evenTrade; amount = 0 }
        else if input.mode == .tradeCreditOnly { outcome = .unusedCredit; amount = remainingTrade }
        else { outcome = .payCustomer; amount = payout }
        return TradeTransactionResult(input: input, tradeApplied: OfferCalculator.cents(tradeApplied),
            remainingTradeCredit: OfferCalculator.cents(remainingTrade), remainingMarketValue: OfferCalculator.cents(marketRemainder),
            cashPayout: OfferCalculator.cents(payout), customerPays: OfferCalculator.cents(customerPays),
            outcome: outcome, finalAmount: OfferCalculator.cents(amount), isPartial: partial, cashValuation: cashValuation)
    }

    /// Display the actual aggregate valuation relative to known market value.
    /// Missing prices cannot establish a whole-list effective percentage.
    static func effectivePercentage(valuation: Decimal, market: Decimal, unpricedQuantity: Int = 0) -> Decimal? {
        guard unpricedQuantity == 0, !valuation.isNaN, valuation >= 0,
              !market.isNaN, market > 0 else { return nil }
        let percentage = valuation / market * 100
        guard !percentage.isNaN, percentage >= 0 else { return nil }
        return OfferCalculator.cents(percentage)
    }
}
