import XCTest
@testable import CardShowScanner

final class MarketEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_270_400) // Deterministic freshness, no network.

    private func activity(skuID: String = "100", pricing: [String: Any]? = nil,
                          windows: [String: Any]? = nil, generatedAt: String = "2026-10-29T00:00:00Z") throws -> OpportunitiesDetails {
        let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
                                 name: "Fixture", set: "Fixture", number: "1", marketPrice: nil,
                                 confidence: 100, printings: ["Holofoil"])
        let row: [String: Any] = [
            "sku_id": skuID, "condition_id": 1, "condition": "Near Mint", "finish": "Holofoil", "language": "English",
            "pricing": pricing ?? ["market_sku": 9, "market_product": 888, "avg_30d": 999, "live_market": 777,
                                   "listed_low_card": 6, "listed_low_ship": 1, "listed_low_total": 7, "direct_low_card": 8],
            "trends": ["windows": windows ?? [
                "30d": ["tcg_qty": 3, "mp_qty": 2, "combined_qty": 5, "tcg_sold_avg": 10, "tcg_market_avg": 111],
                "90d": ["tcg_qty": 10, "tcg_sold_avg": 12],
                "365d": ["tcg_qty": 20, "mp_qty": 4, "tcg_sold_avg": 13]
            ]]
        ]
        let body: [String: Any] = ["meta": ["category_id": 3, "group_id": 1430, "generated_at": generatedAt],
                                   "product": ["product_id": 42, "name": "Fixture", "skus": [skuID: row]]]
        return try OpportunitiesDetails.decode(JSONSerialization.data(withJSONObject: body), for: card,
                                               expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }

    private func publicDetails(skuID: String? = "100", market: Decimal? = 8) -> MarketDetails {
        MarketDetails(quote: MarketQuote(marketPrice: market, skuID: skuID),
                      context: MarketPriceContext(lowPrice: 4, highPrice: 99_999, listingCount: 99))
    }

    func testExactSKUComparesReturnedMarketSoldAndListingEvidenceWithoutFallbacks() throws {
        let evidence = MarketEvidence(publicDetails: publicDetails(), activity: try activity(), now: now)
        XCTAssertEqual(evidence.skuAgreement, .same)
        XCTAssertEqual(evidence.priceComparisons.map(\.id), ["public.market", "public.low", "activity.market", "activity.sold.30", "activity.sold.90", "activity.listed"])
        XCTAssertEqual(evidence.priceComparisons.map(\.price), [8, 4, 9, 10, 12, 6])
        XCTAssertEqual(evidence.priceComparisons.map(\.kind), [.market, .listing, .market, .sold, .sold, .listing])
        XCTAssertEqual(evidence.priceComparisons.last?.label, "OppsV2 listed card (no shipping)")
        XCTAssertEqual(evidence.priceComparisons.filter { $0.kind == .sold }.count, 2,
                       "A product market, blended average, market average or 365d field is not a 30/90d sold comparison")
    }

    func testKnownZeroPricesAndQuantitiesSurviveWhileMissingValuesStayMissing() throws {
        var details = publicDetails(market: 0)
        details.context = MarketPriceContext(lowPrice: 0, highPrice: 0, listingCount: 0)
        let activity = try activity(pricing: ["market_sku": 0, "listed_low_card": NSNull(), "avg_30d": 444],
                                    windows: ["30d": ["tcg_qty": 0, "tcg_sold_avg": 0],
                                              "90d": ["tcg_qty": NSNull(), "mp_qty": 0, "tcg_sold_avg": NSNull()]])
        let evidence = MarketEvidence(publicDetails: details, activity: activity, now: now)
        XCTAssertEqual(evidence.priceComparisons.map(\.price), [0, 0, 0, 0])
        XCTAssertEqual(evidence.volumePoints.map(\.quantity), [0, 0])
        XCTAssertEqual(evidence.volumePoints.map(\.source), ["TCGplayer", "Manapool"])
        XCTAssertEqual(evidence.volumePoints.map(\.windowDays), [30, 90])
        XCTAssertFalse(evidence.priceComparisons.contains { $0.id == "activity.sold.90" })
        XCTAssertFalse(evidence.volumePoints.contains { $0.windowDays == 365 })
    }

    func testConflictingPublicAndActivitySKUsCannotBeComparedButOwnActivityCountsRemainAvailable() throws {
        let evidence = MarketEvidence(publicDetails: publicDetails(skuID: "101"), activity: try activity(), now: now)
        XCTAssertEqual(evidence.skuAgreement, .different)
        XCTAssertEqual(evidence.priceComparisons.map(\.id), ["public.market", "public.low"])
        XCTAssertEqual(evidence.volumePoints.first?.quantity, 3)
        XCTAssertEqual(evidence.volumePoints.first?.source, "TCGplayer")
    }

    func testUnknownPublicSKUDoesNotMixSourcesOrUseSavedCardIdentityAsAReplacement() throws {
        for skuID: String? in [nil, "", "not-a-sku", "0100", " 100"] {
            let evidence = MarketEvidence(publicDetails: publicDetails(skuID: skuID), activity: try activity(), now: now)
            XCTAssertEqual(evidence.skuAgreement, .unavailable)
            XCTAssertEqual(evidence.priceComparisons.map(\.id), ["public.market", "public.low"])
        }
    }

    func testActivityCanStandAloneWhenPublicQuoteIsUnavailable() throws {
        let activity = try activity()
        for details: MarketDetails? in [nil, MarketDetails(quote: nil, context: MarketPriceContext(lowPrice: 999))] {
            let evidence = MarketEvidence(publicDetails: details, activity: activity, now: now)
            XCTAssertEqual(evidence.skuAgreement, .unavailable)
            XCTAssertEqual(evidence.priceComparisons.map(\.id), ["activity.market", "activity.sold.30", "activity.sold.90", "activity.listed"])
            XCTAssertFalse(evidence.volumePoints.isEmpty)
        }
        let empty = MarketEvidence(publicDetails: nil, activity: nil, now: now)
        XCTAssertTrue(empty.priceComparisons.isEmpty)
        XCTAssertTrue(empty.volumePoints.isEmpty)
    }

    func testVolumeWindowsRetainIndependentReportedSourcesAndNeverAggregateOverlappingPeriods() throws {
        let evidence = MarketEvidence(publicDetails: nil, activity: try activity(), now: now)
        XCTAssertEqual(evidence.volumePoints.map(\.id), ["30d.TCGplayer", "30d.Manapool", "90d.TCGplayer", "365d.TCGplayer", "365d.Manapool"])
        XCTAssertEqual(evidence.volumePoints.map(\.quantity), [3, 2, 10, 20, 4])
        XCTAssertEqual(evidence.volumePoints.map(\.windowDays), [30, 30, 90, 365, 365])
        XCTAssertEqual(Set(evidence.volumePoints.map(\.id)).count, evidence.volumePoints.count)
    }

    func testFreshnessUsesProviderTimestampAndCannotBecomeFreshJustBecauseItWasRetrievedNow() throws {
        var details = publicDetails()
        details.metadata = MarketPriceMetadata(source: .openAPI, updatedAt: now.addingTimeInterval(-172_800),
                                               fetchedAt: now, isOffline: true, isCached: true)
        XCTAssertEqual(MarketEvidence(publicDetails: details, activity: nil, now: now).publicDataAge, .older)
        details.metadata?.updatedAt = nil
        XCTAssertEqual(MarketEvidence(publicDetails: details, activity: nil, now: now).publicDataAge, .unknown)
        let old = try activity(generatedAt: "2020-01-01T00:00:00Z")
        XCTAssertEqual(MarketEvidence(publicDetails: nil, activity: old, now: now).activityDataAge, .older)
        let unknown = try activity(generatedAt: "2026-10-29 12:00:00")
        XCTAssertEqual(MarketEvidence(publicDetails: nil, activity: unknown, now: now).activityDataAge, .unknown)
    }

    func testDataAgeClassifiesBoundaryUnknownAndFutureTimesWithoutClamping() {
        XCTAssertEqual(MarketEvidence.dataAge(now, now: now), .withinDay)
        XCTAssertEqual(MarketEvidence.dataAge(now.addingTimeInterval(-86_400), now: now), .withinDay)
        XCTAssertEqual(MarketEvidence.dataAge(now.addingTimeInterval(-86_401), now: now), .older)
        XCTAssertEqual(MarketEvidence.dataAge(now.addingTimeInterval(1), now: now), .future)
        XCTAssertEqual(MarketEvidence.dataAge(nil, now: now), .unknown)
        XCTAssertEqual(MarketEvidence.dataAge(Date(timeIntervalSince1970: .nan), now: now), .unknown)
    }

    func testTimestampRequiresValidISODateAndTimezoneAndSupportsFractionsAndOffsets() throws {
        let utc = try XCTUnwrap(MarketEvidence.timestamp("2026-10-29T14:00:00Z"))
        XCTAssertEqual(MarketEvidence.timestamp("2026-10-29T10:00:00-04:00"), utc)
        XCTAssertEqual(MarketEvidence.timestamp("2026-10-29T14:00:00.250Z")?.timeIntervalSince(utc), 0.25)
        for value: String? in [nil, "", "2026-10-29", "2026-10-29 14:00:00", "2026-10-29T14:00:00",
                              "2026-02-30T14:00:00Z", "2026-13-01T00:00:00Z", "2026-10-29T25:00:00Z",
                              "2026-10-29T14:60:00Z", "2026-10-29T14:00:60Z", "2026-10-29T14:00:00+25:00",
                              "2026-10-29T14:00:00+00:90", " 2026-10-29T14:00:00Z", "2026-10-29T14:00:00Z trailing"] {
            XCTAssertNil(MarketEvidence.timestamp(value), value ?? "nil")
        }
        XCTAssertNotNil(MarketEvidence.timestamp("2024-02-29T14:00:00.123456789Z"))
    }
}
