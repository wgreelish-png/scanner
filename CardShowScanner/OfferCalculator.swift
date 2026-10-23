import Foundation

struct OfferRates: Codable, Equatable {
    var cash: Decimal = 70
    var trade: Decimal = 80
    var maximum: Decimal = 75
    var isValid: Bool { [cash, trade, maximum].allSatisfy { !$0.isNaN && $0 >= 0 && $0 <= 100 } }
}

struct OfferLine {
    var price: Decimal?
    var quantity: Int
    var cashOverride: Decimal? = nil
    var tradeOverride: Decimal? = nil
    var maximumOverride: Decimal? = nil
}

struct OfferTotals: Codable, Equatable {
    var quantity = 0
    var unpricedQuantity = 0
    var market: Decimal = 0
    var cash: Decimal = 0
    var trade: Decimal = 0
    var maximum: Decimal = 0
    var grossCashSpread: Decimal { market - cash }
}

struct OfferSnapshot: Identifiable, Codable {
    var id = UUID()
    var savedAt = Date()
    var rates: OfferRates
    var totals: OfferTotals
    // Immutable calculation inputs preserve manual prices, quantities and overrides.
    var lines: [SavedOfferLine]
    // Optional JSON field preserves snapshots saved before negotiated totals existed.
    // This is the cash amount for the whole list, independent of the rate calculation.
    var customCashOffer: Decimal? = nil
    var selectedCashOffer: Decimal { customCashOffer ?? totals.cash }
    var selectedCashSpread: Decimal { totals.market - selectedCashOffer }
}

struct SavedOfferLine: Codable {
    var inventoryID: UUID
    var name: String
    var productID: String
    var printing: String
    var condition: String
    var language: String
    var price: Decimal?
    var quantity: Int
    var cashOverride: Decimal?
    var tradeOverride: Decimal?
    var maximumOverride: Decimal?
}

enum OfferCalculator {
    static func cents(_ value: Decimal) -> Decimal {
        var source = value, rounded = Decimal.zero
        NSDecimalRound(&rounded, &source, 2, .plain)
        return rounded
    }
    static func calculate(_ lines: [OfferLine], rates: OfferRates) -> OfferTotals {
        precondition(rates.isValid)
        var totals = OfferTotals()
        for line in lines where line.quantity > 0 {
            totals.quantity += line.quantity
            guard let price = line.price, !price.isNaN, price >= 0 else {
                totals.unpricedQuantity += line.quantity; continue
            }
            let quantity = Decimal(line.quantity)
            totals.market += price * quantity
            totals.cash += cents((line.cashOverride ?? (price * rates.cash / 100)) * quantity)
            totals.trade += cents((line.tradeOverride ?? (price * rates.trade / 100)) * quantity)
            totals.maximum += cents((line.maximumOverride ?? (price * rates.maximum / 100)) * quantity)
        }
        totals.market = cents(totals.market)
        return totals
    }
}

enum MoneyInput {
    static func parse(_ text: String) -> Decimal? {
        guard text.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value >= 0 else { return nil }
        return value
    }
}

/// USD input for a negotiated whole-list amount, never a percentage or unit price.
enum CustomOfferAmount {
    static let maximum = Decimal(999_999_999) + Decimal(99) / 100
    static func isValid(_ value: Decimal) -> Bool {
        !value.isNaN && value >= 0 && value <= maximum && OfferCalculator.cents(value) == value
    }
    static func parse(_ text: String) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 12,
              value.range(of: #"^[0-9]+(?:\.[0-9]{0,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), isValid(amount) else { return nil }
        return amount
    }
}
