import XCTest
@testable import CardShowScanner

final class MarketActivityPresentationTests: XCTestCase {
    private func sku(windows: [String: Any]? = nil, opportunity: [String: Any]? = nil) throws -> OpportunitiesSKU {
        var row: [String: Any] = [
            "sku_id": 7437498, "condition_id": 1, "condition": "Near Mint", "finish": "Holofoil", "language": "English",
            "pricing": ["market_sku": 17.86, "live_market": 18.78, "avg_30d": 999],
            "trends": ["windows": windows ?? [
                "30d": ["tcg_qty": 820, "tcg_sold_avg": 18.13, "tcg_market_avg": 18.14, "tcg_sold_avg_with_sh": 19.35],
                "90d": ["tcg_qty": 933, "tcg_sold_avg": 20.24, "tcg_market_avg": 18.42],
                "365d": ["tcg_qty": 8_258, "tcg_sold_avg": NSNull(), "tcg_market_avg": 19.51]
            ]],
            "marketplaces": ["manapool": NSNull(), "tcgplayer": ["listings": []]]
        ]
        if let opportunity { row["opportunity"] = opportunity }
        return try JSONDecoder().decode(OpportunitiesSKU.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testWindowsUseReportedTotalsAndNormalizeByTheirOwnDurations() throws {
        let presentation = MarketActivityPresentation(sku: try sku())
        XCTAssertEqual(presentation.periods.map(\.windowDays), [30, 90, 365])
        XCTAssertEqual(presentation.periods.map(\.tcgQuantity), [820, 933, 8_258])
        XCTAssertEqual(presentation.periods[0].tcgUnitsPerDay!, 820.0 / 30, accuracy: 0.000_001)
        XCTAssertEqual(presentation.periods[1].tcgUnitsPerDay!, 933.0 / 90, accuracy: 0.000_001)
        XCTAssertEqual(presentation.periods[2].tcgUnitsPerDay!, 8_258.0 / 365, accuracy: 0.000_001)
        XCTAssertEqual(presentation.volumePoints.map(\.quantity), [820, 933, 8_258])
        XCTAssertEqual(presentation.volumePoints.map(\.source), ["TCGplayer", "TCGplayer", "TCGplayer"])
        XCTAssertEqual(presentation.volumePoints.last!.unitsPerDay, 8_258.0 / 365, accuracy: 0.000_001)
        XCTAssertEqual(presentation.periods[0].soldAverageWithShipping, Decimal(string: "19.35"))
        XCTAssertTrue(presentation.periods.allSatisfy { $0.manapoolQuantity == nil && $0.manapoolUnitsPerDay == nil })
    }

    func testMarketAverageFallbackIsTypedWithoutReplacingMissingSoldEvidence() throws {
        let presentation = MarketActivityPresentation(sku: try sku())
        XCTAssertEqual(presentation.periods[0].soldAverage, Decimal(string: "18.13"))
        XCTAssertEqual(presentation.periods[0].priceBasis, .soldAverage)
        let annual = presentation.periods[2]
        XCTAssertNil(annual.soldAverage)
        XCTAssertEqual(annual.displayPrice, Decimal(string: "19.51"))
        XCTAssertEqual(annual.priceBasis, .marketAverage)
        XCTAssertTrue(annual.priceBasis!.isFallback)
        XCTAssertEqual(presentation.pricePoints.map(\.price), [Decimal(string: "18.13")!, Decimal(string: "20.24")!, Decimal(string: "19.51")!])
        XCTAssertEqual(presentation.pricePoints.map(\.basis), [.soldAverage, .soldAverage, .marketAverage])
        XCTAssertFalse(presentation.pricePoints.contains { $0.price == 999 }, "Blended pricing.avg_30d is not the chart's window price")
    }

    func testZeroIsReportedButMissingCountsAndPricesAreNotInvented() throws {
        let presentation = MarketActivityPresentation(sku: try sku(windows: [
            "30d": ["tcg_qty": 0, "mp_qty": 0, "tcg_sold_avg": 0, "tcg_market_avg": 5, "combined_qty": 99],
            "90d": ["tcg_qty": NSNull(), "mp_qty": NSNull(), "tcg_sold_avg": NSNull(), "tcg_market_avg": NSNull()],
            "7d": ["tcg_qty": 999, "tcg_sold_avg": 999]
        ]))
        XCTAssertEqual(presentation.periods.map(\.label), ["30 days", "90 days", "1 year"])
        XCTAssertEqual(presentation.volumePoints.map(\.quantity), [0, 0])
        XCTAssertEqual(presentation.volumePoints.map(\.unitsPerDay), [0, 0])
        XCTAssertEqual(presentation.volumePoints.map(\.source), ["TCGplayer", "Manapool"])
        XCTAssertEqual(presentation.pricePoints.map(\.price), [0])
        XCTAssertEqual(presentation.pricePoints.first?.basis, .soldAverage, "A reported sold zero wins over a market fallback")
        XCTAssertNil(presentation.periods[1].displayPrice)
        XCTAssertNil(presentation.periods[1].priceBasis)
        XCTAssertNil(presentation.periods[2].tcgQuantity)
        XCTAssertEqual(presentation.volumePoints.count, 2, "Combined counts and overlapping windows must not be aggregated")
    }

    func testAllBenchmarkRowsRetainTheirSourceValuesAndShippingBases() throws {
        let opportunity: [String: Any] = [
            "is_available": true, "best_source": "tcg", "buy_card": 14.20, "cost_1x": 15.68, "ship_1x": 1.48,
            "benchmarks": [
                "listed_card": ["ref": 15.99], "listed_total": ["ref": 17.48], "avg_30d": ["ref": 18.13],
                "market_sku": ["ref": 17.86], "market_product": ["ref": NSNull()], "listed_direct": ["ref": 18.86]
            ]
        ]
        let presentation = MarketActivityPresentation(sku: try sku(opportunity: opportunity))
        XCTAssertEqual(presentation.benchmarks.map(\.id), ["buy_card", "cost_1x", "listed_card", "listed_total", "avg_30d", "market_sku", "market_product", "listed_direct"])
        XCTAssertEqual(presentation.benchmarks.map(\.value), [Decimal(string: "14.20"), Decimal(string: "15.68"), Decimal(string: "15.99"), Decimal(string: "17.48"), Decimal(string: "18.13"), Decimal(string: "17.86"), nil, Decimal(string: "18.86")])
        XCTAssertEqual(presentation.benchmarks.map(\.includesShipping), [false, true, false, true, false, false, false, false])
        XCTAssertEqual(presentation.benchmarks.map(\.isMarketplaceCost), [true, true, false, false, false, false, false, false])
    }

    func testMissingOpportunityKeepsUnavailableRowsWithoutBorrowingOtherPricing() throws {
        let presentation = MarketActivityPresentation(sku: try sku())
        XCTAssertEqual(presentation.benchmarks.count, 8)
        XCTAssertTrue(presentation.benchmarks.allSatisfy { $0.value == nil })
        XCTAssertEqual(presentation.periods[0].displayPrice, Decimal(string: "18.13"), "Independent sales-window data remains available")
    }
}
