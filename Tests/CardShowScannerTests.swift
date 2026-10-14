import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowScannerTests: XCTestCase {
    func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    func testRepeatedFramesNeverAutomaticallyAddTwice() {
        var gate = RecognitionGate()
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        var result = ScanResult(id: UUID(), candidates: cards, accepted: true, same: false)
        gate.receive(result)
        XCTAssertTrue(gate.consumeAutomatic(result))
        XCTAssertFalse(gate.consumeAutomatic(result))
        result.same = true
        for _ in 0..<10 { gate.receive(result); XCTAssertFalse(gate.consumeAutomatic(result)) }
        result = ScanResult(id: UUID(), candidates: cards, accepted: true, same: false)
        gate.receive(result)
        XCTAssertTrue(gate.consumeAutomatic(result), "A new physical copy is another episode")
    }
    func testAmbiguousAndLowConfidenceNeverAutomaticallyAdd() {
        var gate = RecognitionGate()
        var cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        var scan = ScanResult(id: UUID(), candidates: cards, accepted: false, same: false)
        gate.receive(scan); XCTAssertFalse(gate.consumeAutomatic(scan))
        cards[0].confidence = 40
        scan = ScanResult(id: UUID(), candidates: cards, accepted: true, same: false)
        gate.receive(scan); XCTAssertFalse(gate.consumeAutomatic(scan))
    }
    func testExactVariantsMergeButConditionLanguageAndFinishStaySeparate() throws {
        let container = try store(); let context = container.mainContext
        let list = CardList(name: "Show"); context.insert(list)
        let card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        try CardListService.add(card, to: list, context: context)
        try CardListService.add(card, to: list, context: context)
        var variant = card; variant.identity.condition = "Lightly Played"
        try CardListService.add(variant, to: list, context: context)
        variant = card; variant.identity.language = "Japanese"
        try CardListService.add(variant, to: list, context: context)
        variant = card; variant.identity.printing = "Holofoil"
        try CardListService.add(variant, to: list, context: context)
        try context.save()
        XCTAssertEqual(list.cards.count, 4); XCTAssertEqual(list.quantity, 5)
        XCTAssertEqual(list.cards.first(where: { $0.snapshot.identity == card.identity })?.quantity, 2)
    }
    func testCandidateConfirmationAndPrintingPriceInvalidation() {
        let model = ScannerViewModel()
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        XCTAssertFalse(model.confirmed)
        model.choose(cards[1])
        XCTAssertTrue(model.confirmed)
        XCTAssertEqual(model.selected?.identity.productID, cards[1].identity.productID)
        model.changePrinting("Holofoil")
        XCTAssertEqual(model.selected?.identity.printing, "Holofoil")
        XCTAssertNil(model.selected?.marketPrice)
        XCTAssertNil(model.selected?.identity.skuID)
    }
    func testCSVQuotesAndUnknownPrices() {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.name = "Card, \"Rare\"\nEdition"; card.marketPrice = nil
        let csv = CSVExportService.render([ExportRow(card: card, quantity: 2)])
        XCTAssertTrue(csv.contains("\"Card, \"\"Rare\"\"\nEdition\""))
        XCTAssertTrue(csv.hasSuffix("\"2\",\"\",\"\"\r\n"))
        XCTAssertEqual(CSVExportService.escape("=1+1"), "\"'=1+1\"")
    }
    func testMissingPricesRemainUnknownAndCopiesPreserveQuantities() throws {
        let container = try store(); let context = container.mainContext
        let list = CardList(name: "Show"); context.insert(list)
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]; card.marketPrice = nil
        try CardListService.add(card, to: list, context: context)
        try CardListService.add(card, to: list, context: context)
        try context.save()
        XCTAssertEqual(list.unpricedQuantity, 2)
        XCTAssertNil(list.cards[0].snapshot.marketPrice)
        try CardListService.duplicate(list, context: context)
        let all = try context.fetch(FetchDescriptor<CardList>())
        XCTAssertEqual(all.count, 2); XCTAssertTrue(all.allSatisfy { $0.quantity == 2 })
    }
    func testPersistenceAfterClosingStoreAndCascadeDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("test.store"))
        let schema = Schema([CardList.self, InventoryCard.self, ScanSession.self])
        func write() throws {
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container)
            let list = CardList(name: "Persistent"); context.insert(list)
            try CardListService.add(MockScannerProvider.samples(game: "Pokémon", index: 0)[0], to: list, context: context)
            try context.save()
        }
        try write()
        let reopened = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(reopened)
        let lists = try context.fetch(FetchDescriptor<CardList>())
        XCTAssertEqual(lists.count, 1); XCTAssertEqual(lists[0].quantity, 1)
        context.delete(lists[0]); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 0)
    }
    func testManualAdditionBlocksLaterConfidentUpdateInSameEpisode() {
        var gate = RecognitionGate()
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        var scan = ScanResult(id: UUID(), candidates: cards, accepted: false, same: false)
        gate.receive(scan); gate.markAdded()
        scan.accepted = true
        gate.receive(scan)
        XCTAssertFalse(gate.consumeAutomatic(scan))
    }
    func testBridgePartialFramesPreserveIdentityAndHideClearsState() throws {
        let candidate = TCGBridgeCandidate(ref: "p:123", name: "Demo", number: "1", set: "Demo", confidence: 62,
            printing: "Normal", skuID: "10", marketPrice: 1.25,
            printings: [CardPrinting(label: "Normal", skuID: "10", marketPrice: 1.25)], requiresPrintingSelection: false)
        var normalizer = TCGBridgeNormalizer()
        var wire = TCGBridgeEnvelope(nonce: "n", kind: "scan", same: false, accepted: false, confidence: 62, candidates: [candidate])
        let first = try XCTUnwrap(normalizer.receive(wire, game: "Pokémon"))
        wire.same = true; wire.candidates = nil; wire.confidence = 96; wire.accepted = true
        let refresh = try XCTUnwrap(normalizer.receive(wire, game: "Pokémon"))
        XCTAssertEqual(refresh.id, first.id); XCTAssertEqual(refresh.candidates[0].name, "Demo")
        XCTAssertEqual(refresh.candidates[0].confidence, 96)
        wire.same = false; wire.candidates = [candidate]
        XCTAssertEqual(try normalizer.receive(wire, game: "Pokémon")?.id, first.id)
        let hidden = try normalizer.receive(TCGBridgeEnvelope(nonce: "n", kind: "hide"), game: "Pokémon")
        XCTAssertEqual(hidden?.visible, false)
        wire.same = true; wire.candidates = nil
        XCTAssertNil(try normalizer.receive(wire, game: "Pokémon"))
    }
    func testBridgeRejectsInvalidReferencesAndTooManyCandidates() throws {
        var normalizer = TCGBridgeNormalizer()
        var candidate = TCGBridgeCandidate(ref: "bad", name: "Demo", number: "", set: "", confidence: 95,
            printing: "Normal", printings: [], requiresPrintingSelection: false)
        var wire = TCGBridgeEnvelope(nonce: "n", kind: "scan", same: false, accepted: true, confidence: 95, candidates: [candidate])
        XCTAssertThrowsError(try normalizer.receive(wire, game: "Pokémon"))
        candidate.ref = "p:123"; wire.candidates = Array(repeating: candidate, count: 6)
        XCTAssertThrowsError(try normalizer.receive(wire, game: "Pokémon"))
    }
    func testPrintingQuotesAndAmbiguityConfirmation() {
        let model = ScannerViewModel()
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.requiresPrintingSelection = true
        card.printingQuotes = [CardPrinting(label: "Holofoil", skuID: "22", marketPrice: 4.5)]
        model.choose(card); XCTAssertFalse(model.confirmed)
        model.changePrinting("Holofoil")
        XCTAssertTrue(model.confirmed); XCTAssertEqual(model.selected?.identity.skuID, "22")
        XCTAssertEqual(model.selected?.marketPrice, Decimal(string: "4.5"))
    }
    func testMockProviderSupportsStopAndRestart() async {
        let provider = MockScannerProvider()
        provider.start(game: "Pokémon")
        var first = provider.results.makeAsyncIterator()
        let one = await first.next(); XCTAssertNotNil(one)
        provider.stop()
        provider.start(game: "Magic: The Gathering")
        var second = provider.results.makeAsyncIterator()
        let two = await second.next()
        XCTAssertEqual(two?.candidates.first?.identity.game, "Magic: The Gathering")
        provider.stop()
    }

}
