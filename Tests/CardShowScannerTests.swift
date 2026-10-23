import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowScannerTests: XCTestCase {
    func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    func testRepeatedFramesNeverAutomaticallyAddTwice() async {
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
    func testAmbiguousAndLowConfidenceNeverAutomaticallyAdd() async {
        var gate = RecognitionGate()
        var cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        var scan = ScanResult(id: UUID(), candidates: cards, accepted: false, same: false)
        gate.receive(scan); XCTAssertFalse(gate.consumeAutomatic(scan))
        cards[0].confidence = 40
        scan = ScanResult(id: UUID(), candidates: cards, accepted: true, same: false)
        gate.receive(scan); XCTAssertFalse(gate.consumeAutomatic(scan))
    }
    func testEveryScanRemainsSeparateIncludingExactVariants() async throws {
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
    func testCandidateConfirmationAndPrintingPriceInvalidation() async {
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
    func testCSVQuotesAndUnknownPrices() async {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.name = "Card, \"Rare\"\nEdition"; card.marketPrice = nil
        let csv = CSVExportService.render([ExportRow(card: card, quantity: 2)])
        XCTAssertTrue(csv.contains("\"Card, \"\"Rare\"\"\nEdition\""))
        XCTAssertTrue(csv.hasSuffix("\"2\",\"\",\"\"\r\n"))
        XCTAssertEqual(CSVExportService.escape("=1+1"), "\"'=1+1\"")
    }
    func testMissingPricesRemainUnknownAndCopiesPreserveQuantities() async throws {
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
    func testPersistenceAfterClosingStoreAndCascadeDelete() async throws {
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
    func testManualAdditionBlocksLaterConfidentUpdateInSameEpisode() async {
        var gate = RecognitionGate()
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        var scan = ScanResult(id: UUID(), candidates: cards, accepted: false, same: false)
        gate.receive(scan); gate.markAdded()
        scan.accepted = true
        gate.receive(scan)
        XCTAssertFalse(gate.consumeAutomatic(scan))
    }
    func testBridgePartialFramesPreserveIdentityAndHideClearsState() async throws {
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
    func testBridgeRejectsInvalidReferencesAndTooManyCandidates() async throws {
        var normalizer = TCGBridgeNormalizer()
        var candidate = TCGBridgeCandidate(ref: "bad", name: "Demo", number: "", set: "", confidence: 95,
            printing: "Normal", printings: [], requiresPrintingSelection: false)
        var wire = TCGBridgeEnvelope(nonce: "n", kind: "scan", same: false, accepted: true, confidence: 95, candidates: [candidate])
        XCTAssertThrowsError(try normalizer.receive(wire, game: "Pokémon"))
        candidate.ref = "p:123"; wire.candidates = Array(repeating: candidate, count: 6)
        XCTAssertThrowsError(try normalizer.receive(wire, game: "Pokémon"))
    }
    func testPrintingQuotesAndAmbiguityConfirmation() async {
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

    func testDiagnosticRotationExportAndDataExclusion() async throws {
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
    func testDiagnosticsDisabledAndSampledEvents() async throws {
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

    func testBatchStartIsExplicitAndPreventsSecondActiveSession() async throws {
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
    func testFinishAndReplacementKeepSeparateListsAndQuantities() async throws {
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
    func testInvalidGameReplacementRollsBackAndWrongGameDoesNotAdd() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        XCTAssertThrowsError(try SessionService.replace(session, game: "invalid", context: context))
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
        XCTAssertThrowsError(try SessionService.add(MockScannerProvider.samples(game: "Yu-Gi-Oh!", index: 0)[0], session: session, list: list, context: context))
        XCTAssertEqual(list.quantity, 0)
    }
    func testBatchReopensWithSameIdentityGameRatesAndSavedCards() async throws {
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
    func testOfferPercentagesQuantitiesAndPerCopyOverrides() async {
        let lines = [OfferLine(price: 100, quantity: 2), OfferLine(price: 10, quantity: 3, cashOverride: 1, tradeOverride: 2, maximumOverride: 3)]
        let totals = OfferCalculator.calculate(lines, rates: OfferRates())
        XCTAssertEqual(totals.market, 230); XCTAssertEqual(totals.cash, 143)
        XCTAssertEqual(totals.trade, 166); XCTAssertEqual(totals.maximum, 159)
        XCTAssertEqual(totals.quantity, 5); XCTAssertEqual(totals.grossCashSpread, 87)
    }
    func testUnpricedCopiesExcludedEvenWithOfferOverridesAndZeroIsKnown() async {
        let lines = [OfferLine(price: nil, quantity: 4, cashOverride: 3), OfferLine(price: 0, quantity: 2)]
        let totals = OfferCalculator.calculate(lines, rates: OfferRates())
        XCTAssertEqual(totals.unpricedQuantity, 4); XCTAssertEqual(totals.quantity, 6)
        XCTAssertEqual(totals.market, 0); XCTAssertEqual(totals.cash, 0)
    }
    func testOfferCurrencyRoundingAndNumericInputValidation() async {
        let totals = OfferCalculator.calculate([OfferLine(price: Decimal(string: "0.05"), quantity: 3)], rates: OfferRates())
        XCTAssertEqual(totals.cash, Decimal(string: "0.11"))
        XCTAssertEqual(totals.trade, Decimal(string: "0.12"))
        XCTAssertEqual(totals.maximum, Decimal(string: "0.11"))
        XCTAssertNil(MoneyInput.parse("10abc")); XCTAssertNil(MoneyInput.parse("-2")); XCTAssertNil(MoneyInput.parse("NaN"))
        XCTAssertFalse(OfferRates(cash: 101).isValid)
    }
    func testGlobalDefaultsDoNotRewriteSessionsOrSavedEstimates() async throws {
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
    func testLegacyUnversionedStoreMigrationPreservesDataWithoutCreatingBatch() async throws {
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
    func testDeletingLinkedListPreservesSessionRecordAndClearsActiveState() async throws {
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
            if fail {
                try CardListService.add(card, to: list, context: context)
                session.record(card)
                throw NSError(domain: "TestSave", code: 1)
            }
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
    func testOnlinePriceUsesExactPrintingLanguageAndCondition() async throws {
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
    func testDuplicateScanOrderSurvivesStoreReopenAndCSV() async throws {
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
    func testCompletedSessionCanContinueWithoutReplacingList() async throws {
        let container = try store(), context = container.mainContext
        let original = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: original, context: context))
        try SessionService.finish(original, context: context)
        let other = try SessionService.start(game: "Magic: The Gathering", context: context)
        XCTAssertThrowsError(try SessionService.resume(original, context: context))
        XCTAssertTrue(other.isActive)
        try SessionService.resume(original, context: context, finishingOtherSession: true)
        XCTAssertTrue(original.isActive); XCTAssertFalse(other.isActive)
        XCTAssertEqual(original.listID, list.id)
    }

    func testEditingToSameIdentityNeverMergesAndKeepsScanOrder() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Order"); context.insert(list)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        for card in [cards[0], cards[1], cards[0]] { try CardListService.add(card, to: list, context: context) }
        try context.save()
        let ids = list.orderedCards.map(\.id), dates = list.orderedCards.map(\.addedAt)
        try CardListService.edit(list.orderedCards[1], card: cards[0], quantity: 1,
                                 cashOverride: nil, tradeOverride: nil, maximumOverride: nil, context: context)
        XCTAssertEqual(list.orderedCards.map(\.id), ids)
        XCTAssertEqual(list.orderedCards.map(\.addedAt), dates)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1, 1])
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.productID }, Array(repeating: cards[0].identity.productID, count: 3))
    }
    func testContinueStandaloneAndCompletedListPreservesOffersAndLegacyQuantity() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Legacy quantity"); context.insert(list)
        let card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        let legacy = try InventoryCard(card: card, quantity: 7); context.insert(legacy); list.cards.append(legacy)
        try context.save()
        let session = try SessionService.continueList(list, game: "Pokémon", context: context)
        try SessionService.saveOffer(session, list: list, context: context)
        let saved = session.savedOffersData, listID = list.id, sessionID = session.id
        try SessionService.finish(session, context: context)
        let other = try SessionService.start(game: "Pokémon", context: context)
        XCTAssertThrowsError(try SessionService.continueList(list, game: "Pokémon", context: context))
        let resumed = try SessionService.continueList(list, game: "Pokémon", context: context, finishingOtherSession: true)
        XCTAssertEqual(resumed.id, sessionID); XCTAssertEqual(resumed.listID, listID)
        XCTAssertEqual(resumed.savedOffersData, saved); XCTAssertFalse(other.isActive)
        try SessionService.add(card, session: resumed, list: list, context: context)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [7, 1])
        XCTAssertEqual(list.orderedCards[0].id, legacy.id)
    }
    func testKnownZeroQuoteAndUnavailableConditionDoNotReuseNM() async throws {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]; card.identity.productID = "p:123"
        let data = Data(#"{"items":{"p:123":{"printings":[{"label":"Normal","quotes":{"English|Near Mint":{"market_price":10,"sku_id":100},"English|Damaged":{"market_price":0,"sku_id":101}}}]}}}"#.utf8)
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: 10, skuID: "100"))
        card.identity.condition = "Damaged"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: 0, skuID: "101"))
        card.identity.condition = "Lightly Played"
        XCTAssertNil(try OnlineMarketPricing.parse(data, for: card))
    }
    func testLatePricingResponseCannotOverwriteNewerConditionOrDiscard() async throws {
        let pricing = ControlledPricing()
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: pricing)
        model.receive(ScanResult(id: UUID(), candidates: MockScannerProvider.samples(game: "Pokémon", index: 0), accepted: true, same: false))
        try await waitForRequests(1, pricing: pricing)
        model.changeCondition("Lightly Played")
        XCTAssertNil(model.selected?.marketPrice); XCTAssertNil(model.selected?.identity.skuID)
        try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 2, skuID: "20"))
        for _ in 0..<100 { if !model.priceLoading { break }; await Task.yield() }
        XCTAssertEqual(model.selected?.marketPrice, 2); XCTAssertEqual(model.selected?.identity.skuID, "20")
        await pricing.resolve(0, with: MarketQuote(marketPrice: 10, skuID: "10"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.selected?.marketPrice, 2); XCTAssertEqual(model.selected?.identity.skuID, "20")
        model.refreshPrice(); try await waitForRequests(3, pricing: pricing)
        model.scanNextCard()
        await pricing.resolve(2, with: MarketQuote(marketPrice: 30, skuID: "30"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.selected)
    }
    func testOneTapCandidateConfirmationIgnoresDoubleTapsAndOldQuotes() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let pricing = ControlledPricing()
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: pricing)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: false, same: false))
        try await waitForRequests(1, pricing: pricing)
        model.selectAndAdd(cards[1], list: list, context: context)
        model.selectAndAdd(cards[0], list: list, context: context)
        try await waitForRequests(2, pricing: pricing)
        XCTAssertTrue(model.selectionInProgress); XCTAssertEqual(list.quantity, 0)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 0, skuID: "22"))
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 1)
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.productID, cards[1].identity.productID)
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.condition, "Near Mint")
        XCTAssertEqual(list.orderedCards[0].snapshot.marketPrice, 0)
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.skuID, "22")
        await pricing.resolve(0, with: MarketQuote(marketPrice: 999, skuID: "99"))
        for _ in 0..<10 { await Task.yield() }
        model.selectAndAdd(cards[1], list: list, context: context)
        XCTAssertEqual(list.quantity, 1); XCTAssertNil(model.selected)
        model.stop()
    }
    func testDiscardWhileConfirmingCannotSaveAfterLateQuote() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let pricing = ControlledPricing()
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: pricing)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: true, same: false))
        try await waitForRequests(1, pricing: pricing)
        model.selectAndAdd(cards[1], list: list, context: context)
        try await waitForRequests(2, pricing: pricing)
        model.scanNextCard()
        await pricing.resolve(1, with: MarketQuote(marketPrice: 2, skuID: "20"))
        await pricing.resolve(0, with: MarketQuote(marketPrice: 10, skuID: "10"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(list.quantity, 0); XCTAssertFalse(model.selectionInProgress)
        XCTAssertNil(model.selected); model.stop()
    }
    func testOneTapSaveFailureRetainsEditedPrintingAndConditionForRetry() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        var fail = true
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: TestMarketPricing(), saveCard: { card, session, list, context, ref in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try SessionService.add(card, session: session, list: list, context: context, recognitionRef: ref)
        })
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: true, same: false))
        model.changeCondition("Lightly Played"); model.changePrinting("Holofoil")
        await waitForIdle(model)
        model.selectAndAdd(cards[0], list: list, context: context)
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 0); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.selected?.identity.printing, "Holofoil")
        XCTAssertEqual(model.selected?.identity.condition, "Lightly Played")
        XCTAssertFalse(model.selectionInProgress)
        fail = false
        model.selectAndAdd(cards[0], list: list, context: context)
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 1); XCTAssertNil(model.selected)
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.printing, "Holofoil")
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.condition, "Lightly Played")
        model.stop()
    }
    func testPricingFailureDoesNotBlockExplicitCandidateSave() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: FailingMarketPricing())
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: true, same: false))
        model.selectAndAdd(cards[1], list: list, context: context)
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 1)
        XCTAssertNil(list.orderedCards[0].snapshot.marketPrice)
        XCTAssertNil(list.orderedCards[0].snapshot.identity.skuID)
        XCTAssertNil(model.selected); XCTAssertFalse(model.selectionInProgress)
        model.stop()
    }
    func testUnresponsivePricingHasDeadlineAndCannotChangeSavedCardLater() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let pricing = ControlledPricing()
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: pricing, confirmationTimeout: .milliseconds(30))
        model.start(game: "Pokémon", list: list, context: context, session: session)
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: true, same: false))
        try await waitForRequests(1, pricing: pricing)
        model.selectAndAdd(cards[1], list: list, context: context)
        try await waitForRequests(2, pricing: pricing)
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 1); XCTAssertNil(list.orderedCards[0].snapshot.marketPrice)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 999, skuID: "99"))
        await pricing.resolve(0, with: MarketQuote(marketPrice: 999, skuID: "99"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(list.quantity, 1); XCTAssertNil(list.orderedCards[0].snapshot.marketPrice)
        model.stop()
    }
    private func quickScanFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: CardShowScannerTests.self).url(forResource: "quickscan-detail", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func testCapturedQuickScanNidoranUsesExactConditionAndPrintingQuotes() async throws {
        let data = try quickScanFixture()
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.identity.productID = "p:87718"; card.identity.printing = "Normal"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: Decimal(string: "0.28"), skuID: "1193687"))
        card.identity.condition = "Lightly Played"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: Decimal(string: "0.27"), skuID: "1201033"))
        card.identity.printing = "Reverse Holofoil"; card.identity.condition = "Near Mint"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: Decimal(string: "1.84"), skuID: "1261658"))
    }
    func testCapturedMissingMarketNeverFallsBackToDirectLiveOrOtherPrices() async throws {
        let data = try quickScanFixture()
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.identity.productID = "p:86027"; card.identity.printing = "Reverse Holofoil"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: nil, skuID: "1262173"))
        card.identity.productID = "p:87727"; card.identity.printing = "Normal"; card.identity.condition = "Damaged"
        XCTAssertEqual(try OnlineMarketPricing.parse(data, for: card), MarketQuote(marketPrice: nil, skuID: "1223080"))
    }
    func testCapturedNidoranAlternativeSavesSelectedCardInsteadOfFirstGuess() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: CapturedMarketPricing(data: try quickScanFixture()))
        model.start(game: "Pokémon", list: list, context: context, session: session)
        var cards = Array(MockScannerProvider.samples(game: "Pokémon", index: 0).prefix(3))
        for (index, entry) in [("p:84922", "Drapion"), ("p:86027", "Haunter"), ("p:87718", "Nidoran F")].enumerated() {
            cards[index].identity.productID = entry.0; cards[index].name = entry.1
        }
        model.receive(ScanResult(id: UUID(), candidates: cards, accepted: true, same: false))
        XCTAssertEqual(list.quantity, 0)
        model.selectAndAdd(cards[2], list: list, context: context)
        await waitForIdle(model)
        XCTAssertEqual(list.quantity, 1)
        let saved = try XCTUnwrap(list.orderedCards.first).snapshot
        XCTAssertEqual(saved.identity.productID, "p:87718"); XCTAssertEqual(saved.name, "Nidoran F")
        XCTAssertEqual(saved.marketPrice, Decimal(string: "0.28")); XCTAssertEqual(saved.identity.skuID, "1193687")
        model.stop()
    }
    func testPublicPricingAccessFailureRetainsReviewAndRemainsActionable() async throws {
        XCTAssertThrowsError(try OnlineMarketPricing.validate(status: 401)) { error in
            XCTAssertEqual(error as? MarketPricingFailure, .accessRejected(401))
        }
        XCTAssertThrowsError(try OnlineMarketPricing.validate(status: 403))
        let model = ScannerViewModel(provider: TestScannerProvider(), pricing: RejectedPublicPricing())
        model.receive(ScanResult(id: UUID(), candidates: MockScannerProvider.samples(game: "Pokémon", index: 0), accepted: true, same: false))
        await waitForIdle(model)
        XCTAssertTrue(model.priceMessage?.contains("401") == true)
        XCTAssertFalse(model.priceMessage?.lowercased().contains("sign in") == true)
        XCTAssertNotNil(model.selected); XCTAssertNil(model.selected?.marketPrice)
    }
    private func waitForIdle(_ model: ScannerViewModel) async {
        for _ in 0..<100 {
            if !model.priceLoading && !model.selectionInProgress { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scanner did not finish the selected card")
    }
    private func waitForRequests(_ count: Int, pricing: ControlledPricing) async throws {
        for _ in 0..<100 {
            let received = await pricing.count
            if received >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Pricing request did not start"); throw URLError(.timedOut)
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

private actor ControlledPricing: MarketPricing {
    private var pending: [CheckedContinuation<MarketQuote?, Error>?] = []
    var count: Int { pending.count }
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, with quote: MarketQuote?) {
        let continuation = pending[index]; pending[index] = nil; continuation?.resume(returning: quote)
    }
}

private struct FailingMarketPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { throw URLError(.badServerResponse) }
}

private struct CapturedMarketPricing: MarketPricing {
    let data: Data
    func quote(for card: CardCandidate) async throws -> MarketQuote? { try OnlineMarketPricing.parse(data, for: card) }
}
private struct RejectedPublicPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { throw MarketPricingFailure.accessRejected(401) }
}
