import XCTest
@testable import CardShowScanner

final class TagBundlePricingTests: XCTestCase {
    private func amount(_ value: String) -> Decimal { Decimal(string: value)! }

    private func line(cost: Decimal? = 0, quantity: Int = 1, expenses: Decimal = 0,
                      profit: Decimal? = 0, sticker: Int64? = nil, bulk: Bool = true,
                      fixedFee: Decimal = 0, percentageFee: Decimal = 0,
                      id: UUID = UUID()) -> TagBundleLine {
        TagBundleLine(id: id, quantity: quantity, individualStickerCents: sticker,
            isTwoForOne: bulk, profitInputs: TagProfitInputs(acquisitionCost: cost,
                allocatedExpenses: expenses, minimumDesiredProfit: profit,
                fixedPaymentFee: fixedFee, percentagePaymentFee: percentageFee))
    }

    func testWholeBundleProtectsProfitWithoutRequiringEachCopyToCoverHalfThePrice() {
        let rows = [line(cost: amount("0.80")), line(cost: amount("0.10"))]
        let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne)

        XCTAssertTrue(result.isEligible)
        XCTAssertEqual(result.totalChargeCents, 100)
        XCTAssertEqual(result.breakEvenCents, 90)
        XCTAssertEqual(result.preferredFloorCents, 90)
        XCTAssertEqual(result.eligibleLineIDs, rows.map(\.id))
        XCTAssertTrue(result.excludedLineIDs.isEmpty)
        XCTAssertEqual(result.allocations.map(\.chargedCents), [50, 50])
        XCTAssertNil(result.savingsCents)
        XCTAssertNil(result.manualOverrideWarning)
    }

    func testAcquisitionExpensesAndDesiredProfitCountForEveryCopyButPaymentFeesCountOnce() {
        let rows = [line(cost: amount("0.20"), quantity: 4, expenses: amount("0.05"),
                         profit: amount("0.025"), fixedFee: amount("0.30"), percentageFee: amount("0.10"))]
        let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne,
            paymentFixedFee: amount("0.30"), paymentPercentageFee: amount("0.10"))

        XCTAssertTrue(result.isEligible)
        XCTAssertEqual(result.selectedQuantity, 4)
        XCTAssertEqual(result.totalChargeCents, 200)
        XCTAssertEqual(result.breakEvenCents, 145)
        XCTAssertEqual(result.preferredFloorCents, 156)
        XCTAssertEqual(result.allocations.first?.chargedCents, 200)
    }

    func testOnePaymentFeeIsNotChargedForEachDifferentInventoryRow() {
        let rows = [line(cost: amount("0.20"), fixedFee: amount("0.30")),
                    line(cost: amount("0.20"), fixedFee: amount("0.30"))]
        let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne,
            paymentFixedFee: amount("0.30"), paymentPercentageFee: amount("0.10"))

        XCTAssertTrue(result.isEligible)
        XCTAssertEqual(result.breakEvenCents, 78)
    }

    func testFractionalCentLotCostIsNotRoundedAwayBeforeTheWholeBundleFloor() {
        let result = TagBundlePricing.evaluate(
            lines: [line(cost: amount("0.50000000001"), quantity: 2)], promotion: .twoForOne)

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.breakEvenCents, 101)
        XCTAssertEqual(result.totalChargeCents, 100)
        XCTAssertTrue(result.manualReviewReasons.contains("The complete bundle is below break-even."))
    }

    func testUnsafeBundleKeepsItsProposedPriceAndWarnsBeforeAnyManualOverride() {
        let rows = [line(cost: amount("0.60"), quantity: 2)]
        let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne)

        XCTAssertFalse(result.isEligible)
        XCTAssertTrue(result.requiresManualOverride)
        XCTAssertNotNil(result.manualOverrideWarning)
        XCTAssertEqual(result.totalChargeCents, 100)
        XCTAssertEqual(result.breakEvenCents, 120)
        XCTAssertEqual(result.allocations.reduce(0) { $0 + $1.chargedCents }, 100)
        XCTAssertTrue(result.eligibleLineIDs.isEmpty)
        XCTAssertEqual(result.excludedLineIDs, rows.map(\.id))
    }

    func testDesiredProfitIsProtectedAcrossEverySelectedCopy() {
        let result = TagBundlePricing.evaluate(
            lines: [line(cost: amount("0.30"), quantity: 2, profit: amount("0.30"))], promotion: .twoForOne)

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.breakEvenCents, 60)
        XCTAssertEqual(result.preferredFloorCents, 120)
        XCTAssertTrue(result.manualReviewReasons.contains("The complete bundle is below its desired profit floor."))
    }

    func testUnknownCostAndKnownZeroHaveDifferentEligibility() {
        let known = TagBundlePricing.evaluate(lines: [line(cost: 0, quantity: 2)], promotion: .twoForOne)
        let unknown = TagBundlePricing.evaluate(lines: [line(cost: nil, quantity: 2)], promotion: .twoForOne)

        XCTAssertTrue(known.isEligible)
        XCTAssertEqual(known.breakEvenCents, 0)
        XCTAssertFalse(unknown.isEligible)
        XCTAssertNil(unknown.breakEvenCents)
        XCTAssertEqual(unknown.totalChargeCents, 100)
        XCTAssertTrue(unknown.manualReviewReasons.contains("Some selected cards have unknown acquisition cost."))
    }

    func testUnsetMinimumDesiredProfitNeedsReviewWithoutLosingKnownBreakEven() {
        let result = TagBundlePricing.evaluate(
            lines: [line(cost: amount("0.10"), quantity: 2, profit: nil)], promotion: .twoForOne)

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.breakEvenCents, 20)
        XCTAssertNil(result.preferredFloorCents)
        XCTAssertTrue(result.manualReviewReasons.contains {
            $0.contains("minimum desired profit")
        })
    }

    func testOptionalFiveDollarPromotionsRequireEnablementAndShowSavings() {
        let two = [line(cost: 1, quantity: 2, sticker: 500, bulk: false)]
        let disabled = TagBundlePricing.evaluate(lines: two, promotion: .twoFiveForNine)
        XCTAssertFalse(disabled.isEligible)

        let settings = TagBundleSettings(enabledPromotions: [.twoForOne, .twoFiveForNine, .threeFiveForThirteen])
        let pair = TagBundlePricing.evaluate(lines: two, promotion: .twoFiveForNine, settings: settings)
        let triple = TagBundlePricing.evaluate(
            lines: [line(cost: 1, quantity: 3, sticker: 500, bulk: false)],
            promotion: .threeFiveForThirteen, settings: settings)

        XCTAssertTrue(pair.isEligible)
        XCTAssertEqual(pair.totalChargeCents, 900)
        XCTAssertEqual(pair.savingsCents, 100)
        XCTAssertTrue(triple.isEligible)
        XCTAssertEqual(triple.totalChargeCents, 1_300)
        XCTAssertEqual(triple.savingsCents, 200)
    }

    func testCardsCannotMixCategoryAndIndividualTagPromotions() {
        let taggedBulk = TagBundlePricing.evaluate(
            lines: [line(quantity: 2, sticker: 100)], promotion: .twoForOne)
        let wrongTag = TagBundlePricing.evaluate(
            lines: [line(quantity: 2, sticker: 400, bulk: false)], promotion: .twoFiveForNine,
            settings: .init(enabledPromotions: [.twoFiveForNine]))

        XCTAssertFalse(taggedBulk.isEligible)
        XCTAssertFalse(wrongTag.isEligible)
    }

    func testExistingDiscountDoesNotStackUnlessExplicitlyEnabled() {
        let row = line(quantity: 2)
        let blocked = TagBundlePricing.evaluate(lines: [row], promotion: .twoForOne,
            alreadyDiscountedLineIDs: [row.id])
        let allowed = TagBundlePricing.evaluate(lines: [row], promotion: .twoForOne,
            settings: .init(allowsDiscountStacking: true), alreadyDiscountedLineIDs: [row.id])

        XCTAssertFalse(blocked.isEligible)
        XCTAssertTrue(allowed.isEligible)
    }

    func testAssessmentUsesEverySelectedCopyAndNeverChoosesACheaperSubset() {
        let rows = [line(cost: 0), line(cost: 0), line(cost: 1)]
        let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne)

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.selectedQuantity, 3)
        XCTAssertNil(result.totalChargeCents)
        XCTAssertTrue(result.allocations.isEmpty)
        XCTAssertEqual(result.excludedLineIDs, rows.map(\.id))
    }

    func testAllocationsKeepEveryCentAndResolveEqualRemaindersByStableID() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let promotion = TagBundlePromotion(id: "three-for-one", quantity: 3,
            eligibleStickerCents: nil, bundlePriceCents: 100, isBulkBin: true)
        let rows = [line(id: c), line(id: a), line(id: b)]
        let settings = TagBundleSettings(enabledPromotions: [promotion])
        let result = TagBundlePricing.evaluate(lines: rows, promotion: promotion, settings: settings)
        let reversed = TagBundlePricing.evaluate(lines: Array(rows.reversed()), promotion: promotion, settings: settings)

        XCTAssertTrue(result.isEligible)
        XCTAssertEqual(result.allocations.map(\.chargedCents), [33, 34, 33])
        XCTAssertEqual(result.allocations.reduce(0) { $0 + $1.chargedCents }, 100)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.allocations.map { ($0.id, $0.chargedCents) }),
                       Dictionary(uniqueKeysWithValues: reversed.allocations.map { ($0.id, $0.chargedCents) }))
    }

    func testInvalidMoneyFeesAndQuantitiesCannotBecomeEligible() {
        let invalidRows = [line(cost: -1, quantity: 2), line(cost: .nan, quantity: 2),
            line(quantity: 2, expenses: -1), line(quantity: 2, profit: -1),
            line(quantity: 0), line(quantity: -2)]
        for row in invalidRows {
            XCTAssertFalse(TagBundlePricing.evaluate(lines: [row], promotion: .twoForOne).isEligible)
        }
        for fee in [Decimal(-1), Decimal(1), Decimal.nan] {
            XCTAssertFalse(TagBundlePricing.evaluate(lines: [line(quantity: 2)], promotion: .twoForOne,
                paymentPercentageFee: fee).isEligible)
        }
        XCTAssertFalse(TagBundlePricing.evaluate(lines: [line(quantity: 2)], promotion: .twoForOne,
            paymentFixedFee: -1).isEligible)
    }

    func testEmptyDuplicateAndOverflowingSelectionsAreRejectedWithoutAllocating() {
        let row = line()
        let cases: [[TagBundleLine]] = [[], [row, row], [line(quantity: Int.max), line()]]
        for rows in cases {
            let result = TagBundlePricing.evaluate(lines: rows, promotion: .twoForOne)
            XCTAssertFalse(result.isEligible)
            XCTAssertTrue(result.allocations.isEmpty)
        }
        let excessive = TagBundlePricing.evaluate(
            lines: [line(cost: TagPricing.maximumDollars, quantity: 2)], promotion: .twoForOne)
        XCTAssertFalse(excessive.isEligible)
        XCTAssertNil(excessive.breakEvenCents)
    }
}
