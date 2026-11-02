import XCTest
@testable import CardShowScanner

final class ShowSaleMathTests: XCTestCase {
    private func line(_ price: Decimal?, quantity: Int = 1, id: UUID = UUID()) -> ShowTransactionCardLine {
        .init(inventoryID: id, card: CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Synthetic card", set: "Set", number: "1", marketPrice: price, confidence: 100, printings: ["Normal"]), quantity: quantity)
    }

    func testDefaultTagsRoundEachCopyToNearestDollarBeforeSummingQuantities() {
        let rows = [line(Decimal(string: "8.28"), quantity: 2), line(Decimal(string: "6.77")), line(Decimal(string: "0.49")), line(Decimal(string: "0.50"))]
        XCTAssertEqual(ShowSaleMath.suggestedTotal(rows), 2_400)
        XCTAssertEqual(ShowSaleMath.allocations(rows, receivedCents: 2_400)?.map(\.receivedCents), [1_600, 700, 0, 100])
        XCTAssertEqual(rows[0].card.marketPrice, Decimal(string: "8.28"))
    }

    func testNegotiatedTotalUsesOneMarketPercentageAcrossEveryCard() {
        let rows = [line(100), line(25, quantity: 2)]
        XCTAssertEqual(ShowSaleMath.marketPercentage(rows, receivedCents: 12_000), 80)
        let allocated = ShowSaleMath.allocations(rows, receivedCents: 12_000)
        XCTAssertEqual(allocated?.map(\.receivedCents), [8_000, 4_000])
        XCTAssertEqual(allocated?.reduce(0) { $0 + $1.receivedCents }, 12_000)
        XCTAssertEqual(rows.map { $0.card.marketPrice }, [100, 25])
    }

    func testCentRemaindersAreDeterministicAndNeverLoseOrInventCash() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let rows = [line(1, id: c), line(1, id: a), line(1, id: b)]
        let expected = [ShowSaleAllocation(inventoryID: c, quantity: 1, receivedCents: 0),
            .init(inventoryID: a, quantity: 1, receivedCents: 1), .init(inventoryID: b, quantity: 1, receivedCents: 0)]
        XCTAssertEqual(ShowSaleMath.allocations(rows, receivedCents: 1), expected)
        XCTAssertEqual(ShowSaleMath.allocations(rows, receivedCents: 1), expected)
    }

    func testMissingAndKnownZeroPricesRemainDistinctAndInvalidInputDoesNotAllocate() {
        XCTAssertNil(ShowSaleMath.suggestedTotal([line(nil)]))
        XCTAssertNil(ShowSaleMath.allocations([line(10), line(nil)], receivedCents: 500))
        XCTAssertEqual(ShowSaleMath.suggestedTotal([line(0)]), 0)
        XCTAssertEqual(ShowSaleMath.allocations([line(0)], receivedCents: 0)?.first?.receivedCents, 0)
        XCTAssertNil(ShowSaleMath.marketPercentage([line(0)], receivedCents: 0))
        XCTAssertNil(ShowSaleMath.allocations([line(0)], receivedCents: 100))
        XCTAssertNil(ShowSaleMath.allocations([line(1)], receivedCents: -1))
        let row = line(1)
        XCTAssertNil(ShowSaleMath.allocations([row, row], receivedCents: 1))
    }
}
