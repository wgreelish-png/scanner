import XCTest
@testable import CardShowScanner

final class ShowInventorySortTests: XCTestCase {
    private func item(_ index: Int, name: String = "Same card", set: String = "Set A", number: String = "1",
                      price: Decimal? = 10, quantity: Int = 1, date: TimeInterval = 100) -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: name, set: set, number: number, marketPrice: price, confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
            card: card, quantity: quantity, acquiredAt: Date(timeIntervalSince1970: date))
    }

    func testMarketSortUsesPerCardDecimalPriceAndKeepsUnknownLastInBothDirections() {
        let missing = item(1, price: nil), zero = item(2, price: 0, quantity: 100)
        let high = item(3, price: Decimal(string: "10.000002"))
        let low = item(4, price: Decimal(string: "10.000001"), quantity: 50)
        let source = [missing, high, zero, low]
        XCTAssertEqual(ShowInventorySort.marketAscending.sorted(source).map(\.id), [zero, low, high, missing].map(\.id))
        XCTAssertEqual(ShowInventorySort.marketDescending.sorted(source).map(\.id), [high, low, zero, missing].map(\.id))
        XCTAssertEqual(source, [missing, high, zero, low])
    }

    func testNamesAndSetNumbersUseNaturalOrder() {
        let first = item(1, name: "Card 2", number: "10")
        let second = item(2, name: "Card 10", number: "2")
        let otherSet = item(3, name: "Card 1", set: "Set B")
        let source = [second, otherSet, first]
        XCTAssertEqual(ShowInventorySort.nameAscending.sorted(source).map(\.id), [otherSet, first, second].map(\.id))
        XCTAssertEqual(ShowInventorySort.nameDescending.sorted(source).map(\.id), [second, first, otherSet].map(\.id))
        XCTAssertEqual(ShowInventorySort.setAndNumber.sorted(source).map(\.id), [second, first, otherSet].map(\.id))
    }

    func testQuantityAndAcquisitionDateOrders() {
        let first = item(1, quantity: 2, date: 10)
        let second = item(2, quantity: 1, date: 30)
        let third = item(3, quantity: 4, date: 20)
        let source = [first, second, third]
        XCTAssertEqual(ShowInventorySort.quantityDescending.sorted(source).map(\.id), [third, first, second].map(\.id))
        XCTAssertEqual(ShowInventorySort.newestFirst.sorted(source).map(\.id), [second, third, first].map(\.id))
        XCTAssertEqual(ShowInventorySort.oldestFirst.sorted(source).map(\.id), [first, third, second].map(\.id))
    }

    func testEqualCardsRemainSeparateWithDeterministicIdentityTiesWithoutChangingSource() {
        let first = item(1), second = item(2)
        let source = [second, first]
        for sort in ShowInventorySort.allCases {
            let result = sort.sorted(source)
            XCTAssertEqual(result.map(\.id), [first.id, second.id])
            XCTAssertEqual(result.map(\.quantity), [1, 1])
        }
        XCTAssertEqual(source, [second, first])
    }

    func testUnsupportedSavedPreferenceFallsBackToTheExistingNameOrder() {
        XCTAssertEqual(ShowInventorySort(preference: "unknown-future-option"), .nameAscending)
        XCTAssertEqual(ShowInventorySort(preference: ShowInventorySort.marketDescending.rawValue), .marketDescending)
    }
}
