import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CustomOfferTests: XCTestCase {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func pricedCard(_ value: Decimal = 100) -> CardCandidate {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.marketPrice = value
        return card
    }
    func testCustomAmountAcceptsZeroAndCentsAndRejectsInvalidAmounts() async {
        XCTAssertEqual(CustomOfferAmount.parse("0"), 0)
        XCTAssertEqual(CustomOfferAmount.parse(" 85.50\n"), Decimal(string: "85.50"))
        XCTAssertEqual(CustomOfferAmount.parse("85."), 85)
        XCTAssertEqual(CustomOfferAmount.parse("999999999.99"), CustomOfferAmount.maximum)
        for text in ["", "-1", "NaN", "inf", "1e2", "$85", "85,50", "10.001", "1000000000", "12345678901234567890"] {
            XCTAssertNil(CustomOfferAmount.parse(text), text)
        }
        XCTAssertFalse(CustomOfferAmount.isValid(.nan))
        XCTAssertFalse(CustomOfferAmount.isValid(Decimal(string: "0.001")!))
    }
    func testLegacySnapshotsDecodeWithoutCustomCashAndZeroRoundTrips() async throws {
        let totals = OfferTotals(quantity: 1, market: 100, cash: 70, trade: 80, maximum: 75)
        let legacy = OfferSnapshot(rates: OfferRates(), totals: totals, lines: [])
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "customCashOffer")
        let decoded = try JSONDecoder().decode(OfferSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.customCashOffer)
        XCTAssertEqual(decoded.selectedCashOffer, 70)
        XCTAssertEqual(decoded.selectedCashSpread, 30)
        var free = legacy; free.customCashOffer = 0
        let reopened = try JSONDecoder().decode(OfferSnapshot.self, from: JSONEncoder().encode(free))
        XCTAssertEqual(reopened.customCashOffer, 0)
        XCTAssertEqual(reopened.selectedCashOffer, 0)
        XCTAssertEqual(reopened.selectedCashSpread, 100)
    }
    func testSavingCustomOfferPreservesCalculatedRatesAndEarlierSnapshots() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        session.setRates(OfferRates(cash: 70, trade: 80, maximum: 75))
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        try SessionService.add(pricedCard(), session: session, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 90)
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: nil)
        let saved = try session.savedOffers()
        XCTAssertEqual(saved.count, 3)
        XCTAssertNil(saved[0].customCashOffer)
        XCTAssertEqual(saved[0].selectedCashOffer, 70)
        XCTAssertEqual(saved[1].customCashOffer, 90)
        XCTAssertEqual(saved[1].selectedCashOffer, 90)
        XCTAssertEqual(saved[1].selectedCashSpread, 10)
        XCTAssertEqual(saved[1].totals.cash, 70)
        XCTAssertEqual(saved[1].totals.trade, 80)
        XCTAssertEqual(saved[1].totals.maximum, 75)
        XCTAssertEqual(saved[1].rates, OfferRates(cash: 70, trade: 80, maximum: 75))
        XCTAssertNil(saved[2].customCashOffer)
        XCTAssertEqual(saved[2].selectedCashOffer, 70)
        XCTAssertEqual(list.cards.count, 1)
    }
    func testInvalidCustomAmountDoesNotMutateSavedOffers() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 0)
        let before = session.savedOffersData
        for amount in [Decimal(-1), Decimal.nan, Decimal(string: "0.001")!, CustomOfferAmount.maximum + 1] {
            XCTAssertThrowsError(try SessionService.saveOffer(session, list: list, context: context, customCashOffer: amount))
            XCTAssertEqual(session.savedOffersData, before)
        }
        XCTAssertEqual(try session.savedOffers().first?.customCashOffer, 0)
    }
    func testCustomWholeListOfferSurvivesReopeningWithUnpricedCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("custom-offer.store"))
        let schema = Schema([CardList.self, InventoryCard.self, ScanSession.self])
        func write() throws {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let session = try SessionService.start(game: "Pokémon", context: context)
            session.setRates(OfferRates(cash: 70, trade: 80, maximum: 75))
            let list = try XCTUnwrap(SessionService.list(for: session, context: context))
            var card = pricedCard(); card.marketPrice = nil
            try SessionService.add(card, session: session, list: list, context: context)
            try SessionService.saveOffer(session, list: list, context: context, customCashOffer: Decimal(string: "85.50"))
        }
        try write()
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(reopened)
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<ScanSession>()).first)
        let snapshot = try XCTUnwrap(session.savedOffers().last)
        XCTAssertEqual(snapshot.customCashOffer, Decimal(string: "85.50"))
        XCTAssertEqual(snapshot.selectedCashOffer, Decimal(string: "85.50"))
        XCTAssertEqual(snapshot.totals.unpricedQuantity, 1)
        XCTAssertEqual(snapshot.totals.cash, 0)
        XCTAssertNil(snapshot.lines.first?.price)
    }
}
