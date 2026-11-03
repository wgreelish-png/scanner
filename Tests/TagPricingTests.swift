import XCTest
@testable import CardShowScanner

final class TagPricingTests: XCTestCase {
    private func amount(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func inputs(cost: String? = "0", desired: String? = "0", expenses: String = "0",
                        fixedFee: String = "0", percentageFee: String = "0") -> TagProfitInputs {
        TagProfitInputs(acquisitionCost: cost.map(amount), allocatedExpenses: amount(expenses),
            minimumDesiredProfit: desired.map(amount), fixedPaymentFee: amount(fixedFee),
            percentagePaymentFee: amount(percentageFee))
    }

    func testFinalStickerExamplesUseBulkOrWholeDollarFloorWithoutCents() {
        let examples: [(String, StickerPrice)] = [
            ("0", .twoForOne), ("0.25", .twoForOne), ("0.50", .twoForOne), ("0.74", .twoForOne),
            ("0.75", .individual(100)), ("0.99", .individual(100)), ("1.00", .individual(100)),
            ("1.85", .individual(100)), ("3.75", .individual(300)), ("8.40", .individual(800)),
            ("25.40", .individual(2_500)), ("48.50", .individual(4_800)),
            ("113", .individual(11_000)), ("199", .individual(19_500)),
            ("347", .individual(34_500)), ("589", .individual(58_500))
        ]
        for (market, expected) in examples {
            let evaluation = TagPricing.evaluate(market: amount(market), inputs: inputs())
            XCTAssertEqual(evaluation.tag, expected, market)
            if let cents = evaluation.tag?.integerPriceCents {
                XCTAssertEqual(cents % 100, 0, market)
                XCTAssertFalse(evaluation.tag!.displayText.contains("."), market)
            }
        }
        XCTAssertEqual(StickerPrice.twoForOne.displayText, "2 for $1")
        XCTAssertEqual(StickerPrice.individual(34_500).displayText, "$345")
    }

    func testStickerBoundariesDoNotRoundTheMarketBeforeChoosingATier() {
        let examples: [(String, StickerPrice)] = [
            ("0.749999", .twoForOne), ("0.750001", .individual(100)),
            ("0.999999", .individual(100)), ("1.999999", .individual(100)),
            ("99.999999", .individual(9_900)), ("100", .individual(10_000)),
            ("104.999999", .individual(10_000)), ("105", .individual(10_500)),
            ("999999999.99", .individual(99_999_999_500))
        ]
        for (market, expected) in examples {
            XCTAssertEqual(TagPricing.evaluate(market: amount(market), inputs: inputs()).tag, expected, market)
        }
    }

    func testUnknownMarketAndKnownZeroHaveDifferentOutcomes() {
        let unknown = TagPricing.evaluate(market: nil, inputs: inputs(cost: "2", desired: "1"))
        XCTAssertNil(unknown.tag)
        XCTAssertTrue(unknown.reasons.contains(.missingMarket))
        XCTAssertEqual(unknown.breakEvenCents, 200)
        XCTAssertEqual(unknown.preferredFloorCents, 300)
        XCTAssertNil(unknown.suggestedOfferCents)

        let zero = TagPricing.evaluate(market: 0, inputs: inputs())
        XCTAssertEqual(zero.tag, .twoForOne)
        XCTAssertFalse(zero.reasons.contains(.missingMarket))
        XCTAssertNil(zero.tag?.integerPriceCents)
        XCTAssertNil(zero.suggestedOfferCents)
        XCTAssertTrue(zero.reasons.contains(.bulkRequiresBundleReview))
    }

    func testInvalidMarketsNeverProduceAStickerOrOffer() {
        for market in [Decimal.nan, Decimal(-1), amount("1000000000")] {
            let result = TagPricing.evaluate(market: market, inputs: inputs())
            XCTAssertNil(result.tag)
            XCTAssertNil(result.suggestedOfferCents)
            XCTAssertTrue(result.reasons.contains(.invalidMarket))
        }
    }

    func testBreakEvenAndPreferredFloorsIncludeEveryCostAndRoundUpToTheCent() throws {
        let context = inputs(cost: "3.333333", desired: "1.25", expenses: "0.2", fixedFee: "0.3", percentageFee: "0.029")
        XCTAssertEqual(try TagPricing.floorCents(inputs: context, desiredProfit: 0), 395)
        XCTAssertEqual(try TagPricing.floorCents(inputs: context, desiredProfit: amount("1.25")), 524)
        let evaluation = TagPricing.evaluate(market: amount("8.40"), inputs: context)
        XCTAssertEqual(evaluation.breakEvenCents, 395)
        XCTAssertEqual(evaluation.preferredFloorCents, 524)
        XCTAssertEqual(evaluation.suggestedOfferCents, 760)
        XCTAssertFalse(evaluation.requiresManualReview)

        XCTAssertTrue(TagPricing.validateActualPriceCents(394, inputs: context).contains(.belowBreakEven))
        XCTAssertFalse(TagPricing.validateActualPriceCents(395, inputs: context).contains(.belowBreakEven))
        XCTAssertTrue(TagPricing.validateActualPriceCents(523, inputs: context).contains(.belowPreferredProfit))
        XCTAssertFalse(TagPricing.validateActualPriceCents(524, inputs: context).contains(.belowPreferredProfit))
    }

    func testFractionalCentLotCostIsNotRoundedAwayOrRoundedIntoEveryCopy() throws {
        let perCopy = Decimal(1) / 3
        let context = TagProfitInputs(acquisitionCost: perCopy, minimumDesiredProfit: 0)
        XCTAssertEqual(try TagPricing.floorCents(inputs: context, desiredProfit: 0), 34)
        XCTAssertTrue(TagPricing.validateActualPriceCents(33, inputs: context).contains(.belowBreakEven))
        XCTAssertTrue(TagPricing.validateActualPriceCents(34, inputs: context).isEmpty)
        XCTAssertEqual(context.acquisitionCost, perCopy)
        let barelyOverOneCent = inputs(cost: "0.0100000000000000001")
        XCTAssertEqual(try TagPricing.floorCents(inputs: barelyOverOneCent, desiredProfit: 0), 2)
    }

    func testVeryHighPaymentFeeRemainsSafeAndOutOfRangeFloorsRequireReview() throws {
        let highFee = inputs(cost: "0.01", percentageFee: "0.9999")
        XCTAssertEqual(try TagPricing.floorCents(inputs: highFee, desiredProfit: 0), 10_000)
        XCTAssertTrue(TagPricing.validateActualPriceCents(9_999, inputs: highFee).contains(.belowBreakEven))
        XCTAssertTrue(TagPricing.validateActualPriceCents(10_000, inputs: highFee).isEmpty)
        let excessive = inputs(cost: "1", percentageFee: "0.99999999999999999999")
        XCTAssertThrowsError(try TagPricing.floorCents(inputs: excessive, desiredProfit: 0))
        let evaluation = TagPricing.evaluate(market: 100, inputs: excessive)
        XCTAssertEqual(evaluation.tag, .individual(10_000))
        XCTAssertTrue(evaluation.reasons.contains(.amountOutOfRange))
        XCTAssertNil(evaluation.suggestedOfferCents)
    }

    func testUnprofitableMarketTagStaysProposedAndCannotGenerateAnOffer() {
        let evaluation = TagPricing.evaluate(market: amount("3.75"), inputs: inputs(cost: "3.01", desired: "1"))
        XCTAssertEqual(evaluation.tag, .individual(300))
        XCTAssertEqual(evaluation.breakEvenCents, 301)
        XCTAssertEqual(evaluation.preferredFloorCents, 401)
        XCTAssertTrue(evaluation.reasons.contains(.belowBreakEven))
        XCTAssertTrue(evaluation.reasons.contains(.belowPreferredProfit))
        XCTAssertTrue(evaluation.requiresManualReview)
        XCTAssertNil(evaluation.suggestedOfferCents)
    }

    func testUnknownCostAndUnsetProfitDoNotInventZeroOrSuppressBreakEven() throws {
        let unknownCost = TagPricing.evaluate(market: 25, inputs: inputs(cost: nil, desired: "1"))
        XCTAssertEqual(unknownCost.tag, .individual(2_500))
        XCTAssertNil(unknownCost.breakEvenCents)
        XCTAssertNil(unknownCost.preferredFloorCents)
        XCTAssertNil(unknownCost.suggestedOfferCents)
        XCTAssertTrue(unknownCost.reasons.contains(.unknownAcquisitionCost))
        XCTAssertNil(try TagPricing.floorCents(inputs: inputs(cost: nil), desiredProfit: 0))

        let unsetProfit = TagPricing.evaluate(market: 25, inputs: inputs(cost: "3.333333", desired: nil))
        XCTAssertEqual(unsetProfit.breakEvenCents, 334)
        XCTAssertNil(unsetProfit.preferredFloorCents)
        XCTAssertNil(unsetProfit.suggestedOfferCents)
        XCTAssertTrue(unsetProfit.reasons.contains(.missingMinimumDesiredProfit))
        XCTAssertFalse(unsetProfit.reasons.contains(.unknownAcquisitionCost))

        let explicitZero = TagPricing.evaluate(market: 25, inputs: inputs(cost: "0", desired: "0"))
        XCTAssertEqual(explicitZero.breakEvenCents, 0)
        XCTAssertEqual(explicitZero.preferredFloorCents, 0)
        XCTAssertNotNil(explicitZero.suggestedOfferCents)
    }

    func testInvalidInputsAreReviewReasonsAndNeverGenerateAnOffer() {
        let examples: [(TagProfitInputs, TagPricingReason)] = [
            (inputs(cost: "-1"), .invalidAcquisitionCost),
            (inputs(expenses: "-0.01"), .invalidAllocatedExpenses),
            (inputs(desired: "-1"), .invalidMinimumDesiredProfit),
            (inputs(fixedFee: "-1"), .invalidFixedPaymentFee),
            (inputs(percentageFee: "-0.01"), .invalidPercentagePaymentFee),
            (inputs(percentageFee: "1"), .invalidPercentagePaymentFee),
            (inputs(percentageFee: "2.9"), .invalidPercentagePaymentFee),
            (inputs(cost: "1000000000"), .invalidAcquisitionCost)
        ]
        for (context, reason) in examples {
            let result = TagPricing.evaluate(market: 100, inputs: context)
            XCTAssertEqual(result.tag, .individual(10_000))
            XCTAssertTrue(result.reasons.contains(reason), reason.rawValue)
            XCTAssertTrue(result.requiresManualReview)
            XCTAssertNil(result.suggestedOfferCents)
        }
        var nanFee = inputs()
        nanFee.percentagePaymentFee = .nan
        XCTAssertTrue(TagPricing.validateInputs(nanFee).contains(.invalidPercentagePaymentFee))
        XCTAssertTrue(TagPricing.validateActualPriceCents(-1, inputs: inputs()).contains(.invalidActualPrice))
        XCTAssertTrue(TagPricing.validateActualPriceCents(TagPricing.maximumCents + 1, inputs: inputs()).contains(.invalidActualPrice))
    }

    func testOffersRespectTierDiscountsAndProfitFloors() {
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 300, preferredFloorCents: 0), 300)
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 800, preferredFloorCents: 0), 760)
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 2_500, preferredFloorCents: 0), 2_300)
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 10_000, preferredFloorCents: 0), 9_500)
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 2_000, preferredFloorCents: 1_875), 1_900)
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 2_000, preferredFloorCents: 1_950), 2_000)
        XCTAssertNil(TagPricing.suggestedOfferCents(stickerCents: 2_000, preferredFloorCents: 2_001))

        for sticker: Int64 in [100, 200, 300, 400, 500, 800, 1_900, 2_000, 2_500, 9_900, 10_000, 11_000, 58_500] {
            for floor: Int64 in [0, sticker / 2, sticker - 1, sticker] {
                let result = TagPricing.suggestedOfferCents(stickerCents: sticker, preferredFloorCents: floor)
                XCTAssertNotNil(result)
                XCTAssertGreaterThanOrEqual(result!, floor)
                XCTAssertLessThanOrEqual(result!, sticker)
                let discount = 1 - Decimal(result!) / Decimal(sticker)
                let maximum: Decimal = sticker < 2_000 ? amount("0.05") : (sticker < 10_000 ? amount("0.08") : amount("0.10"))
                XCTAssertLessThanOrEqual(discount, maximum)
                if result! < sticker && sticker >= 500 { XCTAssertGreaterThanOrEqual(discount, amount("0.05")) }
            }
        }
    }

    func testDiscountPreferencesAreValidatedWithinRequestedRanges() {
        let defaults = TagDiscountPolicy()
        XCTAssertEqual(defaults.underFive, amount("0.025"))
        XCTAssertEqual(defaults.fiveToTwenty, amount("0.05"))
        XCTAssertEqual(defaults.twentyToHundred, amount("0.065"))
        XCTAssertEqual(defaults.hundredAndAbove, amount("0.075"))
        XCTAssertTrue(defaults.isValid)
        var custom = defaults
        custom.twentyToHundred = amount("0.05")
        XCTAssertEqual(TagPricing.suggestedOfferCents(stickerCents: 2_000, preferredFloorCents: 0, discounts: custom), 1_900)
        custom.twentyToHundred = amount("0.081")
        XCTAssertFalse(custom.isValid)
        XCTAssertNil(TagPricing.suggestedOfferCents(stickerCents: 2_000, preferredFloorCents: 0, discounts: custom))
        XCTAssertTrue(TagPricing.evaluate(market: 20, inputs: inputs(), discounts: custom).reasons.contains(.invalidDiscountPolicy))
        custom = defaults
        custom.underFive = .nan
        XCTAssertFalse(custom.isValid)
    }

    func testProfitInputsAndStickerCategorySurviveCodableRoundTrip() throws {
        let original = inputs(cost: "1.234567", desired: nil, expenses: "0.2", fixedFee: "0.3", percentageFee: "0.029")
        XCTAssertEqual(try JSONDecoder().decode(TagProfitInputs.self, from: JSONEncoder().encode(original)), original)
        for sticker in [StickerPrice.twoForOne, .individual(34_500)] {
            XCTAssertEqual(try JSONDecoder().decode(StickerPrice.self, from: JSONEncoder().encode(sticker)), sticker)
        }
    }
}
