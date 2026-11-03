import Foundation
import XCTest
@testable import CardShowScanner

final class RepricingPolicyTests: XCTestCase {
    private func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func evaluate(_ baseline: String?, _ current: String?, sticker: Int64? = 0) -> RepricingEvaluation {
        RepricingPolicy.evaluate(baselineMarket: baseline.map(decimal), currentMarket: current.map(decimal),
                                 approvedStickerCents: sticker)
    }

    func testApprovalMarketChoosesTheThresholdTierAtEveryBoundary() {
        let cases = [("4.99", "0.50", "1.00"), ("5", "0.50", "1.00"),
                     ("19.99", "1.00", "2.00"), ("20", "1.00", "2.00")]
        for (baseline, decrease, increase) in cases {
            let result = evaluate(baseline, baseline)
            XCTAssertEqual(result.decreaseThreshold, decimal(decrease), baseline)
            XCTAssertEqual(result.increaseThreshold, decimal(increase), baseline)
            XCTAssertTrue(result.reasons.isEmpty, baseline)
        }
    }

    func testDecreaseAndIncreaseUseDifferentFloorsAndRates() {
        let cases = [("0", "0.25", "0.50"), ("1", "0.25", "0.50"),
                     ("4", "0.40", "0.80"), ("10", "0.50", "1.00"),
                     ("15", "0.75", "1.50"), ("40", "2.00", "4.00"),
                     ("100", "5.00", "10.00")]
        for (baseline, decrease, increase) in cases {
            let result = evaluate(baseline, baseline)
            XCTAssertEqual(result.decreaseThreshold, decimal(decrease), baseline)
            XCTAssertEqual(result.increaseThreshold, decimal(increase), baseline)
        }
    }

    func testFractionalCentThresholdsAlwaysRoundUp() {
        let cases = [("4.91", "0.50", "0.99"), ("11.01", "0.56", "1.11"),
                     ("20.01", "1.01", "2.01")]
        for (baseline, decrease, increase) in cases {
            let result = evaluate(baseline, baseline)
            XCTAssertEqual(result.decreaseThreshold, decimal(decrease), baseline)
            XCTAssertEqual(result.increaseThreshold, decimal(increase), baseline)
        }

        XCTAssertFalse(evaluate("11.01", "10.4595").reasons.contains(.marketDecrease))
        XCTAssertFalse(evaluate("11.01", "10.46").reasons.contains(.marketDecrease))
        XCTAssertTrue(evaluate("11.01", "10.45").reasons.contains(.marketDecrease))
        XCTAssertFalse(evaluate("11.01", "12.111").reasons.contains(.marketIncrease))
        XCTAssertFalse(evaluate("11.01", "12.11").reasons.contains(.marketIncrease))
        XCTAssertTrue(evaluate("11.01", "12.12").reasons.contains(.marketIncrease))
    }

    func testMovementIsInclusiveAtTheThresholdAndExcludesThePreviousCent() {
        let cases = [("1", "0.25", "0.50"), ("4.99", "0.50", "1.00"),
                     ("5", "0.50", "1.00"), ("19.99", "1.00", "2.00"),
                     ("20", "1.00", "2.00"), ("500", "25.00", "25.00"),
                     ("1000", "25.00", "25.00")]
        let cent = decimal("0.01")
        for (baselineText, decreaseText, increaseText) in cases {
            let baseline = decimal(baselineText)
            let decrease = decimal(decreaseText), increase = decimal(increaseText)
            let fallingAt = RepricingPolicy.evaluate(baselineMarket: baseline, currentMarket: baseline - decrease,
                                                     approvedStickerCents: 0)
            let fallingBelow = RepricingPolicy.evaluate(baselineMarket: baseline, currentMarket: baseline - decrease + cent,
                                                        approvedStickerCents: 0)
            let risingAt = RepricingPolicy.evaluate(baselineMarket: baseline, currentMarket: baseline + increase,
                                                    approvedStickerCents: 0)
            let risingBelow = RepricingPolicy.evaluate(baselineMarket: baseline, currentMarket: baseline + increase - cent,
                                                       approvedStickerCents: 0)
            XCTAssertTrue(fallingAt.reasons.contains(.marketDecrease), baselineText)
            XCTAssertFalse(fallingBelow.reasons.contains(.marketDecrease), baselineText)
            XCTAssertTrue(risingAt.reasons.contains(.marketIncrease), baselineText)
            XCTAssertFalse(risingBelow.reasons.contains(.marketIncrease), baselineText)
        }
    }

    func testBothHighValueThresholdsCapAtTwentyFiveDollars() {
        let cases = [("250", "12.50", "25.00"), ("499.99", "25.00", "25.00"),
                     ("500", "25.00", "25.00"), ("500.01", "25.00", "25.00"),
                     ("1000", "25.00", "25.00"), ("999999999.99", "25.00", "25.00")]
        for (baseline, decrease, increase) in cases {
            let result = evaluate(baseline, baseline)
            XCTAssertEqual(result.decreaseThreshold, decimal(decrease), baseline)
            XCTAssertEqual(result.increaseThreshold, decimal(increase), baseline)
        }
    }

    func testCrossingMarketTiersDoesNotMoveTheApprovalThreshold() {
        XCTAssertFalse(evaluate("5", "4.54").reasons.contains(.marketDecrease))
        XCTAssertFalse(evaluate("20", "19.02").reasons.contains(.marketDecrease))
        XCTAssertTrue(evaluate("19", "21").reasons.contains(.marketIncrease))
        XCTAssertTrue(evaluate("4", "4.80").reasons.contains(.marketIncrease))
    }

    func testRepeatedImportsContinueComparingAgainstTheLastApprovedMarket() {
        let firstImport = evaluate("10", "10.40")
        let secondImport = evaluate("10", "10.80")
        let thirdImport = evaluate("10", "11.00")
        XCTAssertFalse(firstImport.reasons.contains(.marketIncrease))
        XCTAssertFalse(secondImport.reasons.contains(.marketIncrease))
        XCTAssertTrue(thirdImport.reasons.contains(.marketIncrease))
        XCTAssertEqual(thirdImport.baselineMarket, decimal("10"))
        XCTAssertEqual(thirdImport.marketDelta, decimal("1"))

        let afterApproval = evaluate("11", "11")
        XCTAssertTrue(afterApproval.reasons.isEmpty)
        XCTAssertEqual(afterApproval.marketDelta, Decimal.zero)
    }

    func testCompetitivenessUsesCurrentMarketTierAndIncludesTheExactPremiumBoundary() {
        let cases: [(String, String, Int64, Int64)] = [
            ("4", "4.40", 440, 441), ("5", "5.40", 540, 541),
            ("10", "10.80", 1_080, 1_081), ("20", "21.00", 2_100, 2_101),
            ("1000", "1050.00", 105_000, 105_001)
        ]
        for (market, limit, atBoundary, aboveBoundary) in cases {
            let below = evaluate(market, market, sticker: atBoundary - 1)
            let at = evaluate(market, market, sticker: atBoundary)
            let above = evaluate(market, market, sticker: aboveBoundary)
            XCTAssertEqual(at.competitivenessLimit, decimal(limit), market)
            XCTAssertFalse(below.reasons.contains(.overpriced), market)
            XCTAssertTrue(at.reasons.contains(.overpriced), market)
            XCTAssertTrue(above.reasons.contains(.overpriced), market)
            XCTAssertFalse(above.reasons.contains(.marketDecrease), market)
            XCTAssertFalse(above.reasons.contains(.marketIncrease), market)
        }
    }

    func testZeroMarketOnlyFlagsAPositiveSticker() {
        let free = evaluate("0", "0", sticker: 0)
        XCTAssertEqual(free.competitivenessLimit, Decimal.zero)
        XCTAssertFalse(free.reasons.contains(.overpriced))
        XCTAssertTrue(evaluate("0", "0", sticker: 1).reasons.contains(.overpriced))
    }

    func testCompetitivenessKeepsFractionalCentLimitsExactAtTierEdges() {
        let low = evaluate("4.99", "4.99", sticker: 548)
        XCTAssertEqual(low.competitivenessLimit, decimal("5.489"))
        XCTAssertFalse(low.reasons.contains(.overpriced))
        XCTAssertTrue(evaluate("4.99", "4.99", sticker: 549).reasons.contains(.overpriced))

        let mid = evaluate("19.99", "19.99", sticker: 2_158)
        XCTAssertEqual(mid.competitivenessLimit, decimal("21.5892"))
        XCTAssertFalse(mid.reasons.contains(.overpriced))
        XCTAssertTrue(evaluate("19.99", "19.99", sticker: 2_159).reasons.contains(.overpriced))

        let crossed = evaluate("20", "19.99", sticker: 2_110)
        XCTAssertFalse(crossed.reasons.contains(.overpriced))
        XCTAssertEqual(crossed.competitivenessLimit, decimal("21.5892"))
    }

    func testCompetitivenessCanFlagAStickerWithoutSignificantMarketMovement() {
        let result = evaluate("10", "9.99", sticker: 1_100)
        XCTAssertEqual(result.reasons, [.overpriced])
        XCTAssertEqual(result.marketDelta, decimal("-0.01"))

        let combined = evaluate("10", "9", sticker: 1_000)
        XCTAssertTrue(combined.reasons.contains(.marketDecrease))
        XCTAssertTrue(combined.reasons.contains(.overpriced))
    }

    func testMissingMarketNeverBecomesAKnownZeroQuote() {
        let missing = evaluate("10", nil, sticker: 1_000)
        XCTAssertNil(missing.currentMarket)
        XCTAssertNil(missing.marketDelta)
        XCTAssertNil(missing.competitivenessLimit)
        XCTAssertEqual(missing.reasons, [.marketUnavailable])

        let zero = evaluate("10", "0", sticker: 1_000)
        XCTAssertEqual(zero.currentMarket, Decimal.zero)
        XCTAssertEqual(zero.marketDelta, decimal("-10"))
        XCTAssertEqual(zero.competitivenessLimit, Decimal.zero)
        XCTAssertFalse(zero.reasons.contains(.marketUnavailable))
        XCTAssertTrue(zero.reasons.contains(.marketDecrease))
        XCTAssertTrue(zero.reasons.contains(.overpriced))

        let zeroApproval = evaluate("0", "0", sticker: 0)
        XCTAssertTrue(zeroApproval.reasons.isEmpty)
        XCTAssertEqual(zeroApproval.marketDelta, Decimal.zero)
        XCTAssertFalse(evaluate("0", "0.49").reasons.contains(.marketIncrease))
        XCTAssertTrue(evaluate("0", "0.50").reasons.contains(.marketIncrease))
    }

    func testNewPricingRequiresBothAnApprovedMarketAndAnApprovedSticker() {
        let unapproved = evaluate(nil, "10", sticker: nil)
        XCTAssertEqual(unapproved.reasons, [.newPricing])
        XCTAssertNil(unapproved.baselineMarket)
        XCTAssertNil(unapproved.marketDelta)
        XCTAssertNil(unapproved.increaseThreshold)
        XCTAssertNil(unapproved.decreaseThreshold)
        XCTAssertEqual(evaluate("10", "10", sticker: nil).reasons, [.newPricing])
        XCTAssertEqual(evaluate(nil, "10", sticker: 1_000).reasons, [.newPricing])

        let missingEverything = evaluate(nil, nil, sticker: nil)
        XCTAssertTrue(missingEverything.reasons.contains(.newPricing))
        XCTAssertTrue(missingEverything.reasons.contains(.marketUnavailable))
        XCTAssertFalse(missingEverything.reasons.contains(.overpriced))
    }

    func testApprovedBulkCategoryDoesNotRequireAnIndividualStickerPrice() {
        let unchanged = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: decimal("10"),
                                                  approvedStickerCents: nil, hasApprovedCategory: true)
        XCTAssertTrue(unchanged.reasons.isEmpty)
        XCTAssertEqual(unchanged.marketDelta, Decimal.zero)
        XCTAssertFalse(unchanged.reasons.contains(.overpriced))

        let decreased = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: decimal("9.50"),
                                                  approvedStickerCents: nil, hasApprovedCategory: true)
        XCTAssertEqual(decreased.reasons, [.marketDecrease])
        let increased = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: decimal("11"),
                                                  approvedStickerCents: nil, hasApprovedCategory: true)
        XCTAssertEqual(increased.reasons, [.marketIncrease])

        let missingBaseline = RepricingPolicy.evaluate(baselineMarket: nil, currentMarket: decimal("10"),
                                                       approvedStickerCents: nil, hasApprovedCategory: true)
        XCTAssertEqual(missingBaseline.reasons, [.newPricing])
        let missingMarket = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: nil,
                                                     approvedStickerCents: nil, hasApprovedCategory: true)
        XCTAssertEqual(missingMarket.reasons, [.marketUnavailable])

        let noApprovedCategory = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: decimal("10"),
                                                          approvedStickerCents: nil)
        XCTAssertEqual(noApprovedCategory.reasons, [.newPricing])
    }

    func testInvalidOrOutOfRangeInputsStayUnavailableAndNeverTriggerArithmetic() {
        let invalidMarkets = [Decimal.nan, decimal("-0.01"), decimal("1000000000")]
        for invalid in invalidMarkets {
            let current = RepricingPolicy.evaluate(baselineMarket: decimal("10"), currentMarket: invalid,
                                                   approvedStickerCents: 1_000)
            XCTAssertNil(current.currentMarket)
            XCTAssertNil(current.marketDelta)
            XCTAssertNil(current.competitivenessLimit)
            XCTAssertEqual(current.reasons, [.marketUnavailable])

            let baseline = RepricingPolicy.evaluate(baselineMarket: invalid, currentMarket: decimal("10"),
                                                    approvedStickerCents: 1_000)
            XCTAssertNil(baseline.baselineMarket)
            XCTAssertNil(baseline.marketDelta)
            XCTAssertNil(baseline.increaseThreshold)
            XCTAssertNil(baseline.decreaseThreshold)
            XCTAssertEqual(baseline.reasons, [.newPricing])
        }
        for invalidSticker in [Int64(-1), 100_000_000_000, Int64.max] {
            let result = evaluate("10", "10", sticker: invalidSticker)
            XCTAssertEqual(result.reasons, [.newPricing])
            XCTAssertFalse(result.reasons.contains(.overpriced))
        }
        XCTAssertFalse(evaluate("999999999.99", "999999999.99", sticker: 99_999_999_999)
            .reasons.contains(.marketUnavailable))
    }

    func testDeltaPreservesDecimalPrecisionWithoutCentRounding() {
        let result = evaluate("10.1234", "11.2345")
        XCTAssertEqual(result.baselineMarket, decimal("10.1234"))
        XCTAssertEqual(result.currentMarket, decimal("11.2345"))
        XCTAssertEqual(result.marketDelta, decimal("1.1111"))
        XCTAssertEqual(evaluate("11.2345", "10.1234").marketDelta, decimal("-1.1111"))
    }

    func testDecreasesAndOverpricedStickersSortAheadOfIncreases() {
        let decrease = evaluate("10", "9")
        let overpriced = evaluate("10", "10", sticker: 1_081)
        let newPricing = evaluate(nil, "10", sticker: nil)
        let unavailable = evaluate("10", nil, sticker: 1_000)
        let increase = evaluate("10", "11")
        let clean = evaluate("10", "10")
        XCTAssertEqual(decrease.priority, 0)
        XCTAssertEqual(overpriced.priority, 0)
        XCTAssertEqual(newPricing.priority, 1)
        XCTAssertEqual(unavailable.priority, 2)
        XCTAssertEqual(increase.priority, 3)
        XCTAssertEqual(clean.priority, 4)
        XCTAssertLessThan(decrease.priority, increase.priority)
        XCTAssertLessThan(overpriced.priority, increase.priority)
    }
}
