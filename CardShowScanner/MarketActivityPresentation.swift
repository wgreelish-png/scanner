import Foundation

/// A comparison of overlapping reported windows, never calendar history.
/// Values are read-only and do not change saved prices, offers or inventory.
struct MarketActivityPresentation: Equatable, Sendable {
    let periods: [MarketActivityPeriod]
    let volumePoints: [MarketActivityVolumePoint]
    let pricePoints: [MarketActivityPricePoint]
    let benchmarks: [MarketActivityBenchmark]

    init(sku: OpportunitiesSKU) {
        periods = [30, 90, 365].map { days in
            let window = sku.trends?.windows["\(days)d"]
            let sold = window?.tcgSoldAverage
            let market = window?.tcgMarketAverage
            return MarketActivityPeriod(windowDays: days, tcgQuantity: window?.tcgQuantity,
                manapoolQuantity: window?.manapoolQuantity, soldAverage: sold, marketAverage: market,
                displayPrice: sold ?? market,
                priceBasis: sold != nil ? .soldAverage : market != nil ? .marketAverage : nil,
                soldAverageWithShipping: window?.tcgSoldAverageWithShipping,
                manapoolAverage: window?.manapoolAverage)
        }
        volumePoints = periods.flatMap { period -> [MarketActivityVolumePoint] in
            [("TCGplayer", period.tcgQuantity), ("Manapool", period.manapoolQuantity)].compactMap { source, quantity in
                guard let quantity else { return nil }
                return MarketActivityVolumePoint(id: "\(period.windowDays)d.\(source)", windowDays: period.windowDays,
                    source: source, quantity: quantity, unitsPerDay: Double(quantity) / Double(period.windowDays))
            }
        }
        pricePoints = periods.compactMap { period in
            guard let price = period.displayPrice, let basis = period.priceBasis else { return nil }
            return MarketActivityPricePoint(id: "\(period.windowDays)d.TCGplayer", windowDays: period.windowDays,
                                            price: price, basis: basis)
        }
        let opportunity = sku.opportunity
        let references = opportunity?.benchmarks ?? [:]
        benchmarks = [
            MarketActivityBenchmark(id: "buy_card", label: "Buy card", value: opportunity?.buyCard, includesShipping: false),
            MarketActivityBenchmark(id: "cost_1x", label: "Landed 1×", value: opportunity?.costOne, includesShipping: true),
            MarketActivityBenchmark(id: "listed_card", label: "Listed card", value: references["listed_card"]?.reference, includesShipping: false),
            MarketActivityBenchmark(id: "listed_total", label: "Listed + shipping", value: references["listed_total"]?.reference, includesShipping: true),
            MarketActivityBenchmark(id: "avg_30d", label: "30-day reference average", value: references["avg_30d"]?.reference, includesShipping: false),
            MarketActivityBenchmark(id: "market_sku", label: "SKU market", value: references["market_sku"]?.reference, includesShipping: false),
            MarketActivityBenchmark(id: "market_product", label: "Product market", value: references["market_product"]?.reference, includesShipping: false),
            MarketActivityBenchmark(id: "listed_direct", label: "Direct low", value: references["listed_direct"]?.reference, includesShipping: false)
        ]
    }
}

enum MarketActivityPriceBasis: String, Equatable, Sendable {
    case soldAverage, marketAverage

    var title: String { self == .soldAverage ? "Sold average" : "Market average" }
    var isFallback: Bool { self == .marketAverage }
}

struct MarketActivityPeriod: Identifiable, Equatable, Sendable {
    let windowDays: Int
    var id: Int { windowDays }
    var label: String { windowDays == 365 ? "1 year" : "\(windowDays) days" }
    let tcgQuantity: Int?
    var tcgUnitsPerDay: Double? { tcgQuantity.map { Double($0) / Double(windowDays) } }
    let manapoolQuantity: Int?
    var manapoolUnitsPerDay: Double? { manapoolQuantity.map { Double($0) / Double(windowDays) } }
    let soldAverage: Decimal?
    let marketAverage: Decimal?
    /// The provider example's sold-average → market-average fallback, with its basis retained.
    let displayPrice: Decimal?
    let priceBasis: MarketActivityPriceBasis?
    let soldAverageWithShipping: Decimal?
    let manapoolAverage: Decimal?
}

struct MarketActivityVolumePoint: Identifiable, Equatable, Sendable {
    let id: String
    let windowDays: Int
    let source: String
    let quantity: Int
    let unitsPerDay: Double
}

struct MarketActivityPricePoint: Identifiable, Equatable, Sendable {
    let id: String
    let windowDays: Int
    let price: Decimal
    let basis: MarketActivityPriceBasis
}

struct MarketActivityBenchmark: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// Missing benchmarks stay visible as unavailable in the detailed values.
    let value: Decimal?
    let includesShipping: Bool
    var isMarketplaceCost: Bool { id == "buy_card" || id == "cost_1x" }
}
