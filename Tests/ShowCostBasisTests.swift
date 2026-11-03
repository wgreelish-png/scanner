import XCTest
@testable import CardShowScanner

final class ShowCostBasisTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func row(_ price: Decimal? = nil, quantity: Int = 1, weight: Int64? = nil,
                     allocation: Int64? = nil, id: UUID = UUID()) -> ShowIncomingCard {
        ShowIncomingCard(id: id, card: CardCandidate(identity: .init(game: "Pokémon", productID: id.uuidString,
            printing: "Normal"), name: "Cost fixture", set: "Set", number: "1", marketPrice: price,
            confidence: 100, printings: ["Normal"]), quantity: quantity,
            costWeightCents: weight, allocatedCostCents: allocation)
    }

    func testPartialLotsRecoverEveryCentAcrossDifferentCheckoutSizes() throws {
        for groups in [[1, 1, 1], [2, 1], [1, 2], [3]] {
            var remaining: Int64 = 1_000, quantity = 3, costs: [Int64] = []
            for group in groups {
                let cost = try XCTUnwrap(ShowCostBasisMath.consumedCost(totalCostCents: remaining,
                    quantity: quantity, consumedQuantity: group))
                costs.append(cost); remaining -= cost; quantity -= group
            }
            XCTAssertEqual(costs.reduce(0, +), 1_000)
            XCTAssertEqual(remaining, 0)
            XCTAssertEqual(quantity, 0)
        }
        XCTAssertEqual(try ShowCostBasisMath.consumedCost(totalCostCents: 1_000, quantity: 3, consumedQuantity: 1), 334)
        XCTAssertEqual(try ShowCostBasisMath.consumedCost(totalCostCents: 666, quantity: 2, consumedQuantity: 1), 333)
        XCTAssertNil(try ShowCostBasisMath.consumedCost(totalCostCents: nil, quantity: 3, consumedQuantity: 1))
        XCTAssertEqual(try ShowCostBasisMath.consumedCost(totalCostCents: 0, quantity: 3, consumedQuantity: 1), 0)
        XCTAssertThrowsError(try ShowCostBasisMath.consumedCost(totalCostCents: 100, quantity: 2, consumedQuantity: 3))
    }

    func testLargestRemainderUsesStableLotIdentityAndConservesNegotiatedTotal() throws {
        let ids = [third, first, second]
        XCTAssertEqual(try ShowCostBasisMath.allocate(totalCents: 1, ids: ids, weights: [1, 1, 1]), [0, 1, 0])
        XCTAssertEqual(try ShowCostBasisMath.allocate(totalCents: 2, ids: ids, weights: [1, 1, 1]), [0, 1, 1])
        XCTAssertEqual(try ShowCostBasisMath.allocate(totalCents: 701, ids: ids, weights: [1, 2, 4]), [100, 200, 401])
        let reordered = try ShowCostBasisMath.allocate(totalCents: 2, ids: [second, third, first], weights: [1, 1, 1])
        XCTAssertEqual(reordered, [1, 0, 1])
        XCTAssertThrowsError(try ShowCostBasisMath.allocate(totalCents: 100, ids: [first, second], weights: [0, 0]))
        XCTAssertThrowsError(try ShowCostBasisMath.allocate(totalCents: 100, ids: [first, first], weights: [1, 1]))
        XCTAssertEqual(try ShowCostBasisMath.allocate(totalCents: 0, ids: [first, second], weights: [0, 0]), [0, 0])
    }

    func testActualPurchaseTotalUsesOffersIncludingOverridesAndQuantity() throws {
        let offers = [row(100, quantity: 2, weight: 600, id: first), row(20, weight: 400, id: second)]
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(offers, totalCostCents: 700), [420, 280])
        let fallback = [row(10, quantity: 2, id: first), row(10, id: second)]
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(fallback, totalCostCents: 900), [600, 300])
        let mixed = [row(100, weight: 1_000, id: first), row(10, id: second)]
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(mixed, totalCostCents: 700), [350, 350],
                       "A supplied offer weight must survive a reference fallback on another row")
    }

    func testMissingWeightsNeedReviewButOneLotAndKnownZeroNeedNoMarketQuote() throws {
        let missing = [row(id: first), row(id: second)]
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts(missing, totalCostCents: 700))
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(missing, totalCostCents: 0), [0, 0])
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts([row(id: first)], totalCostCents: 700), [700])
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(missing, totalCostCents: nil), [nil, nil])
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts([row(0, id: first), row(0, id: second)], totalCostCents: 700))
    }

    func testReviewedAllocationsStayFixedWhileUnspecifiedLotsShareTheResidual() throws {
        let reviewed = [row(allocation: 123, id: first), row(allocation: 577, id: second)]
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts(reviewed, totalCostCents: 700), [123, 577])
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts(reviewed, totalCostCents: 701))
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts([row(allocation: 123, id: first), row(id: second)],
            totalCostCents: 700), [123, 577], "One unspecified lot has an unambiguous residual cost")
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts([row(allocation: 123, id: first),
            row(weight: 2, id: second), row(weight: 1, id: third)], totalCostCents: 700), [123, 385, 192])
        XCTAssertEqual(try ShowCostBasisMath.incomingCosts([row(allocation: 700, id: first),
            row(id: second), row(id: third)], totalCostCents: 700), [700, 0, 0])
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts([row(allocation: 701, id: first),
            row(id: second)], totalCostCents: 700))
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts([row(allocation: 100, id: first),
            row(id: second), row(id: third)], totalCostCents: 700),
            "Multiple unspecified lots still require usable weights or reviewed costs")
        XCTAssertThrowsError(try ShowCostBasisMath.incomingCosts(reviewed, totalCostCents: nil),
                             "Reviewed weights cannot invent a cost for an unknown-basis trade")
    }

    func testTradeCashConsumesBasisBeforeRecognizingCashProfit() throws {
        let cases: [(Int64, Int64, Int64, Int64)] = [
            (0, 0, 4_000, 0), (2_000, 0, 6_000, 0), (0, 2_000, 2_000, 0),
            (0, 6_000, 0, 2_000), (1_000, 6_000, 0, 1_000)
        ]
        for (paid, received, cost, profit) in cases {
            let actual = try ShowCostBasisMath.carriedTradeCost(outgoingCostCents: 4_000,
                paidCents: paid, receivedCents: received)
            XCTAssertEqual(actual.incomingCostCents, cost)
            XCTAssertEqual(actual.profitCents, profit)
        }
        let unknown = try ShowCostBasisMath.carriedTradeCost(outgoingCostCents: nil, paidCents: 0, receivedCents: 6_000)
        XCTAssertNil(unknown.incomingCostCents); XCTAssertNil(unknown.profitCents)
        let zero = try ShowCostBasisMath.carriedTradeCost(outgoingCostCents: 0, paidCents: 0, receivedCents: 1_000)
        XCTAssertEqual(zero.incomingCostCents, 0); XCTAssertEqual(zero.profitCents, 1_000)
        XCTAssertThrowsError(try ShowCostBasisMath.carriedTradeCost(outgoingCostCents: ShowBudgetMoney.maximumCents,
            paidCents: 1, receivedCents: 0))
    }
}
