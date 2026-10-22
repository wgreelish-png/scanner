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
    func testEveryScanRemainsSeparateIncludingExactVariants() throws {
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
        XCTAssertEqual(list.cards.count, 5); XCTAssertEqual(list.quantity, 5)
        XCTAssertTrue(list.cards.allSatisfy { $0.quantity == 1 })
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
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let list = CardList(name: "Persistent"); context.insert(list)
            try CardListService.add(MockScannerProvider.samples(game: "Pokémon", index: 0)[0], to: list, context: context)
            try context.save()
        }
        try write()
        let reopened = try ModelContainer(for: schema, configurations: [config])
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
        XCTAssertTrue(model.confirmed); XCTAssertNil(model.selected?.identity.skuID)
        XCTAssertNil(model.selected?.marketPrice, "An old cached printing quote must not masquerade as an online value")
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

    func testDiagnosticRotationExportAndDataExclusion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CardShowScanner.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "diagnosticsEnabled")
        let log = DiagnosticLog(directory: directory, maximumBytes: 2048, defaults: defaults)
        for _ in 0..<100 { log.record("scan.test", ["confidence": "95", "card_name": "PRIVATE_CARD", "reason": "Bearer PRIVATE_TOKEN"]) }
        XCTAssertFalse(log.storageFailed)
        for name in ["current.jsonl", "previous.jsonl"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 2048)
        }
        let url = try log.export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_CARD")); XCTAssertFalse(text.contains("PRIVATE_TOKEN"))
        for line in text.split(separator: "\n") { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        XCTAssertTrue(text.contains("diagnostics.environment"))
        try log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current.jsonl").path))
    }
    func testDiagnosticsDisabledAndSampledEvents() throws {
        let suite = "CardShowScanner.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        defaults.set(false, forKey: "diagnosticsEnabled")
        log.record("disabled.event")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        defaults.set(true, forKey: "diagnosticsEnabled")
        for _ in 0..<20 { log.record("scan.sampled", sampleEvery: 60) }
        let lines = try String(contentsOf: directory.appendingPathComponent("current.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        log.failure("test.failed", NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_URL_TOKEN"]))
        let text = try String(contentsOf: directory.appendingPathComponent("current.jsonl"), encoding: .utf8)
        XCTAssertTrue(text.contains("-1009")); XCTAssertFalse(text.contains("PRIVATE_URL_TOKEN"))
    }

    func testBatchStartIsExplicitAndPreventsSecondActiveSession() throws {
        let container = try store(), context = container.mainContext
        XCTAssertNil(try SessionService.active(context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 0)
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        XCTAssertTrue(session.isActive); XCTAssertEqual(session.game, "Pokémon")
        XCTAssertTrue(list.name.hasSuffix("Pokémon")); XCTAssertEqual(list.createdAt, session.startedAt)
        XCTAssertThrowsError(try SessionService.start(game: "Pokémon", context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
    }
    func testFinishAndReplacementKeepSeparateListsAndQuantities() throws {
        let container = try store(), context = container.mainContext
        let original = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: original, context: context))
        let card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        try SessionService.add(card, session: original, list: list, context: context)
        list.name = "Renamed"; try context.save()
        let replacement = try SessionService.replace(original, game: "Magic: The Gathering", context: context)
        XCTAssertFalse(original.isActive); XCTAssertNotNil(original.completedAt)
        XCTAssertEqual(list.quantity, 1); XCTAssertEqual(original.listID, list.id)
        XCTAssertNotEqual(replacement.listID, original.listID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 2)
        XCTAssertThrowsError(try SessionService.add(card, session: original, list: list, context: context))
        try SessionService.finish(replacement, context: context)
        XCTAssertNil(try SessionService.active(context: context))
    }
    func testInvalidGameReplacementRollsBackAndWrongGameDoesNotAdd() throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        XCTAssertThrowsError(try SessionService.replace(session, game: "invalid", context: context))
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
        XCTAssertThrowsError(try SessionService.add(MockScannerProvider.samples(game: "Yu-Gi-Oh!", index: 0)[0], session: session, list: list, context: context))
        XCTAssertEqual(list.quantity, 0)
    }
    func testBatchReopensWithSameIdentityGameRatesAndSavedCards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("batch.store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id: UUID
        let listID: UUID?
        do {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let session = try SessionService.start(game: "Pokémon", context: context)
            id = session.id; listID = session.listID
            let list = try XCTUnwrap(SessionService.list(for: session, context: context))
            try SessionService.add(MockScannerProvider.samples(game: "Pokémon", index: 0)[0], session: session, list: list, context: context)
        }
        let reopened = try AppPersistence.open(url: url), context = reopened.mainContext
        let restored = try XCTUnwrap(SessionService.active(context: context))
        XCTAssertEqual(restored.id, id); XCTAssertEqual(restored.listID, listID); XCTAssertEqual(restored.game, "Pokémon")
        XCTAssertEqual(restored.lastConsumedRecognitionRef, MockScannerProvider.samples(game: "Pokémon", index: 0)[0].identity.productID)
        XCTAssertEqual(try SessionService.list(for: restored, context: context)?.quantity, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
    }
    func testOfferPercentagesQuantitiesAndPerCopyOverrides() {
        let lines = [OfferLine(price: 100, quantity: 2), OfferLine(price: 10, quantity: 3, cashOverride: 1, tradeOverride: 2, maximumOverride: 3)]
        let totals = OfferCalculator.calculate(lines, rates: OfferRates())
        XCTAssertEqual(totals.market, 230); XCTAssertEqual(totals.cash, 143)
        XCTAssertEqual(totals.trade, 166); XCTAssertEqual(totals.maximum, 159)
        XCTAssertEqual(totals.quantity, 5); XCTAssertEqual(totals.grossCashSpread, 87)
    }
    func testUnpricedCopiesExcludedEvenWithOfferOverridesAndZeroIsKnown() {
        let lines = [OfferLine(price: nil, quantity: 4, cashOverride: 3), OfferLine(price: 0, quantity: 2)]
        let totals = OfferCalculator.calculate(lines, rates: OfferRates())
        XCTAssertEqual(totals.unpricedQuantity, 4); XCTAssertEqual(totals.quantity, 6)
        XCTAssertEqual(totals.market, 0); XCTAssertEqual(totals.cash, 0)
    }
    func testOfferCurrencyRoundingAndNumericInputValidation() {
        let totals = OfferCalculator.calculate([OfferLine(price: Decimal(string: "0.05"), quantity: 3)], rates: OfferRates())
        XCTAssertEqual(totals.cash, Decimal(string: "0.11"))
        XCTAssertEqual(totals.trade, Decimal(string: "0.12"))
        XCTAssertEqual(totals.maximum, Decimal(string: "0.11"))
        XCTAssertNil(MoneyInput.parse("10abc")); XCTAssertNil(MoneyInput.parse("-2")); XCTAssertNil(MoneyInput.parse("NaN"))
        XCTAssertFalse(OfferRates(cash: 101).isValid)
    }
    func testGlobalDefaultsDoNotRewriteSessionsOrSavedEstimates() throws {
        let suite = "BatchTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(65, forKey: "pricingPercentage")
        let container = try store(), context = container.mainContext
        let batch = try SessionService.start(game: "Pokémon", context: context, defaults: defaults)
        let list = try XCTUnwrap(SessionService.list(for: batch, context: context))
        XCTAssertEqual(batch.rates.cash, 65); XCTAssertEqual(defaults.string(forKey: "defaultGame"), "Pokémon")
        try SessionService.add(MockScannerProvider.samples(game: "Pokémon", index: 0)[0], session: batch, list: list, context: context)
        try SessionService.saveOffer(batch, list: list, context: context)
        let original = try XCTUnwrap(batch.savedOffers().first)
        defaults.set(50, forKey: "cashPercentage")
        list.cards[0].quantity = 10; batch.setRates(OfferRates(cash: 60)); try context.save()
        let saved = try XCTUnwrap(batch.savedOffers().first)
        XCTAssertEqual(saved.totals, original.totals); XCTAssertEqual(saved.rates.cash, 65)
        XCTAssertEqual(saved.lines[0].quantity, 1); XCTAssertEqual(batch.rates.cash, 60)
    }
    func testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let listID: UUID, historyID: UUID
        do {
            // No versioned container/plan: reproduces the original app's unversioned store.
            let schema = Schema(ScannerSchemaV1.models)
            let config = ModelConfiguration("default", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config]), context = container.mainContext
            let list = ScannerSchemaV1.CardList(name: "Legacy list"); listID = list.id; context.insert(list)
            let data = try JSONEncoder().encode(MockScannerProvider.samples(game: "Pokémon", index: 0)[0])
            let card = ScannerSchemaV1.InventoryCard(data: data, quantity: 3); context.insert(card); list.cards.append(card)
            let history = ScannerSchemaV1.ScanSession(listName: "Legacy list"); historyID = history.id
            history.addedQuantity = 3; history.knownValueText = "3.75"; context.insert(history); try context.save()
        }
        let migrated = try AppPersistence.open(url: url), context = migrated.mainContext
        let lists = try context.fetch(FetchDescriptor<CardList>()), history = try context.fetch(FetchDescriptor<ScanSession>())
        XCTAssertEqual(lists.count, 1); XCTAssertEqual(lists[0].id, listID); XCTAssertEqual(lists[0].quantity, 3)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].id, historyID); XCTAssertEqual(history[0].knownValue, Decimal(string: "3.75"))
        XCTAssertNil(history[0].listID); XCTAssertFalse(history[0].isActive)
        XCTAssertNil(try SessionService.active(context: context))
        XCTAssertNil(lists[0].cards[0].cashOverrideText)
    }
    func testDeletingLinkedListPreservesSessionRecordAndClearsActiveState() throws {
        let container = try store(), context = container.mainContext
        let batch = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: batch, context: context))
        try SessionService.deleteList(list, context: context)
        XCTAssertNil(batch.listID); XCTAssertFalse(batch.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScanSession>()), 1)
        XCTAssertNil(try SessionService.active(context: context))
    }

    func testReviewIgnoresNewFramesAndKeepsCondition() async throws {
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: TestMarketPricing())
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        let first = ScanResult(id: UUID(), candidates: cards, accepted: true, same: false)
        model.receive(first)
        XCTAssertEqual(model.selected?.identity.condition, "Near Mint")
        model.changeCondition("Lightly Played")
        model.receive(ScanResult(id: UUID(), candidates: Array(cards.reversed()), accepted: true, same: false))
        model.receive(ScanResult(id: UUID(), candidates: [], accepted: false, same: true, visible: false))
        XCTAssertEqual(model.result?.id, first.id)
        XCTAssertEqual(model.selected?.identity.condition, "Lightly Played")
        for _ in 0..<50 { if !model.priceLoading { break }; await Task.yield() }
        XCTAssertEqual(model.selected?.marketPrice, 2)
    }
    func testSaveFailureKeepsReviewAndRetryAddsOnlyOnce() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        var fail = true
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: TestMarketPricing(), saveCard: { card, session, list, context, ref in
            if fail { throw NSError(domain: "TestSave", code: 1) }
            try SessionService.add(card, session: session, list: list, context: context, recognitionRef: ref)
        })
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let scan = ScanResult(id: UUID(), candidates: MockScannerProvider.samples(game: "Pokémon", index: 0), accepted: true, same: false)
        model.receive(scan)
        for _ in 0..<50 { if !model.priceLoading { break }; await Task.yield() }
        model.addSelected(list: list, context: context)
        XCTAssertNotNil(model.error); XCTAssertNotNil(model.selected)
        XCTAssertEqual(list.quantity, 0); XCTAssertNil(session.lastConsumedRecognitionRef)
        fail = false
        model.addSelected(list: list, context: context)
        XCTAssertNil(model.selected); XCTAssertEqual(list.quantity, 1)
        model.addSelected(list: list, context: context)
        model.receive(scan)
        XCTAssertEqual(list.quantity, 1); XCTAssertNil(model.selected)
        model.scanNextCard(); model.receive(scan)
        XCTAssertNotNil(model.selected, "An intentional next-card action allows an identical copy")
        model.stop()
    }
    func testOnlinePriceUsesExactPrintingLanguageAndCondition() throws {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.identity.productID = "p:123"
        let data = Data(#"{"items":{"p:123":{"printings":[{"key":"Normal","label":"Normal","market_price":99,"quotes":{"English|Near Mint":{"market_price":5,"sku_id":10},"English|Lightly Played":{"market_price":2,"sku_id":"11"}}}]}}}"#.utf8)
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: 5, skuID: "10"))
        card.identity.condition = "Lightly Played"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: 2, skuID: "11"))
        card.identity.condition = "Damaged"
        XCTAssertNil(try OnlineMarketPricing.parse(data, for: card))
        card.identity.condition = "Near Mint"; card.identity.printing = "Holofoil"
        XCTAssertNil(try OnlineMarketPricing.parse(data, for: card))
    }
    func testDuplicateScanOrderSurvivesStoreReopenAndCSV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("order.store")
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        let expected = [cards[0], cards[1], cards[0]]
        do {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let session = try SessionService.start(game: "Pokémon", context: context)
            let list = try XCTUnwrap(SessionService.list(for: session, context: context))
            for card in expected { try SessionService.add(card, session: session, list: list, context: context) }
        }
        let container = try AppPersistence.open(url: url), context = container.mainContext
        let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity }, expected.map(\.identity))
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1, 1])
        let csv = CSVExportService.render(list.orderedCards.map { ExportRow(card: $0.snapshot, quantity: $0.quantity) })
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 4)
    }
    func testCompletedSessionCanContinueWithoutReplacingList() throws {
        let container = try store(), context = container.mainContext
        let original = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: original, context: context))
        try SessionService.finish(original, context: context)
        let other = try SessionService.start(game: "Magic: The Gathering", context: context)
        try SessionService.resume(original, context: context)
        XCTAssertTrue(original.isActive); XCTAssertFalse(other.isActive)
        XCTAssertEqual(original.listID, list.id)
    }

}

@MainActor private final class TestScannerProvider: ScannerProvider {
    let label = "Test"
    let results: AsyncStream<ScanResult> = AsyncStream { _ in }
    func start(game: String) {}
    func stop() {}
    func clearCache() async throws {}
}
private struct TestMarketPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        MarketQuote(marketPrice: card.identity.condition == "Near Mint" ? 5 : 2, skuID: "10")
    }
}
