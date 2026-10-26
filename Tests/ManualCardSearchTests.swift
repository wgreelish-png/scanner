import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ManualCardSearchTests: XCTestCase {
    private func cache() throws -> (ScannerDatabaseCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ScannerDatabaseCache(directory: directory), directory)
    }
    private func tagged(_ value: Any) throws -> Data {
        var data = Data([0]); data.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])); return data
    }
    private func row(_ id: Int, _ name: String, _ number: String = "1/102", _ set: String = "Triumphant", _ printing: String = "Normal") -> [Any] {
        ["p:\(id)", name, number, "TM", set, "", "https://cdn.tcgtracking.com/product/\(id)_400w.jpg",
         [["label": printing, "primary": true, "id": 777, "nm": 999]]]
    }
    private func install(_ rows: [[Any]], in cache: ScannerDatabaseCache, game: String = "tcgp:3", version: String = "first") async throws {
        let path = game.replacingOccurrences(of: ":", with: "-") + "/" + version + ".json"
        let directory = String(path.prefix(through: path.lastIndex(of: "/")!))
        try await cache.write("cur:" + game, data: tagged(path))
        try await cache.write("M:" + path, data: tagged(["v": 2, "shards": [["meta": version + "-meta", "n": rows.count]]]))
        try await cache.write("m:" + directory + version + "-meta", data: tagged(["k": 1, "refs": rows]))
    }
    func testNameSearchReturnsFiveDistinctPreviewCardsAndNeverCachedPrices() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        var rows = (1...8).map { row($0, "Darkrai", "\($0)/102", "Set \($0)") }
        rows += [row(1, "Darkrai", "1/102", "Set 1", "Reverse Holofoil"), row(99, "Pikachu")]
        try await install(rows, in: cache)
        let results = try await CachedCardCatalog(cache: cache).search("darkrai", game: "Pokémon", limit: 100)
        XCTAssertEqual(results.count, 5); XCTAssertEqual(Set(results.map { $0.identity.productID }).count, 5)
        XCTAssertTrue(results.allSatisfy { $0.name == "Darkrai" && $0.imageURL != nil })
        XCTAssertTrue(results.allSatisfy { $0.marketPrice == nil && $0.identity.skuID == nil })
        XCTAssertEqual(results.first?.printings, ["Normal", "Reverse Holofoil"])
    }
    func testNumberSetAndPartialNameNarrowLegendTopInsteadOfOtherDarkraiCards() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([row(7001, "Darkrai & Cresselia LEGEND (Top)", "99/102"),
            row(7002, "Darkrai & Cresselia LEGEND (Bottom)", "100/102"), row(7003, "Darkrai", "199/200"),
            row(7004, "Darkrai", "099/102", "Other Set"), row(7005, "Pikachu", "99/102")], in: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let refined = try await catalog.search("DÁRKRAI 99 triumphant", game: "Pokémon", limit: 5)
        XCTAssertEqual(refined.map { $0.identity.productID }, ["p:7001"])
        let exact = try await catalog.search("darkra top 99/102 TM", game: "Pokémon", limit: 5)
        XCTAssertEqual(exact.map { $0.identity.productID }, ["p:7001"])
        let bottom = try await catalog.search("darkrai 100", game: "Pokémon", limit: 5)
        XCTAssertEqual(bottom.map { $0.identity.productID }, ["p:7002"])
    }
    func testGameIsolationManifestUpdateAndCacheClearInvalidateResults() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([row(1, "Darkrai")], in: cache)
        try await install([row(2, "Dark Ritual")], in: cache, game: "tcgp:1")
        let catalog = CachedCardCatalog(cache: cache)
        let magic = try await catalog.search("dark", game: "Magic: The Gathering", limit: 5)
        XCTAssertEqual(magic.map { $0.identity.productID }, ["p:2"])
        let pokemon = try await catalog.search("dark", game: "Pokémon", limit: 5)
        XCTAssertEqual(pokemon.map { $0.identity.productID }, ["p:1"])
        try await install([row(3, "Darkrai ex")], in: cache, version: "second")
        let updated = try await catalog.search("dark", game: "Pokémon", limit: 5)
        XCTAssertEqual(updated.map { $0.identity.productID }, ["p:3"])
        try await cache.clear()
        do { _ = try await catalog.search("dark", game: "Pokémon", limit: 5); XCTFail("Cleared data must not be served from memory") }
        catch { XCTAssertTrue(error is CardCatalogFailure) }
    }
    func testPrefixedCardNumbersCanRefineNamesWithoutBreakingNamesContainingDigits() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([row(1, "Mimikyu", "TG01/TG30"), row(2, "Mimikyu", "TG02/TG30"), row(3, "Porygon2", "147/200")], in: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let trainer = try await catalog.search("mimikyu tg1", game: "Pokémon", limit: 5)
        XCTAssertEqual(trainer.map { $0.identity.productID }, ["p:1"])
        let named = try await catalog.search("porygon2", game: "Pokémon", limit: 5)
        XCTAssertEqual(named.map { $0.identity.productID }, ["p:3"])
    }
    func testIncompleteMetadataDoesNotPretendToBeTheCompleteCatalog() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await cache.write("cur:tcgp:3", data: tagged("pokemon/first.json"))
        try await cache.write("M:pokemon/first.json", data: tagged(["v": 2, "shards": [["meta": "missing"]]]))
        do { _ = try await CachedCardCatalog(cache: cache).search("darkrai", game: "Pokémon", limit: 5); XCTFail("Missing metadata must be visible") }
        catch { XCTAssertTrue(error is CardCatalogFailure) }
    }
    func testLegacyNativeMetadataCanBeSearchedWithoutStartingHashEngine() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await cache.write("index", data: tagged(["games": ["tcgp:3": ["ver": "old"]]]))
        let refs = try JSONSerialization.data(withJSONObject: [row(9, "Darkrai", "9/102")])
        let count = refs.count
        var native = Data([2, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        native.append(refs); native.append(Data([1, 2, 3]))
        try await cache.write("tcgp:3@old", data: native)
        let cards = try await CachedCardCatalog(cache: cache).search("darkrai", game: "Pokémon", limit: 5)
        XCTAssertEqual(cards.map { $0.identity.productID }, ["p:9"])
    }
    func testMalformedRowsAreSkippedAndUnsafeImagesDoNotBecomePreviewURLs() async throws {
        let (cache, directory) = try cache(); defer { try? FileManager.default.removeItem(at: directory) }
        var unsafe = row(3, "Darkrai"); unsafe[6] = "javascript:alert(1)"
        var thumbnail = row(4, "Darkrai"); thumbnail[6] = "https://cdn.tcgtracking.com/product/4_200w.jpg"
        try await install([["bad", "Darkrai"], row(2, ""), unsafe, thumbnail], in: cache)
        let cards = try await CachedCardCatalog(cache: cache).search("darkrai", game: "Pokémon", limit: 5)
        XCTAssertEqual(cards.count, 2); XCTAssertEqual(cards[0].imageURL?.scheme, "https")
        XCTAssertEqual(cards[0].imageURL?.host, "cdn.tcgtracking.com")
        XCTAssertEqual(cards.first { $0.identity.productID == "p:4" }?.imageURL?.lastPathComponent, "4_400w.jpg")
    }
    func testLatestTypedQueryWinsWhenOlderSearchFinishesLater() async throws {
        let catalog = ControlledCardCatalog(), model = ManualCardSearchModel(game: "Pokémon", catalog: catalog, debounce: .zero)
        model.updateQuery("darkrai"); try await requests(1, catalog)
        model.updateQuery("darkrai 99"); try await requests(2, catalog)
        let chosen = card(99)
        await catalog.resolve(1, with: [chosen]); await idle(model)
        await catalog.resolve(0, with: [card(1)])
        for _ in 0..<15 { await Task.yield() }
        XCTAssertEqual(model.results.map { $0.identity.productID }, [chosen.identity.productID])
        XCTAssertEqual(model.query, "darkrai 99"); XCTAssertNil(model.error)
        model.cancel()
    }
    func testCancelledSearchCannotChangeItsResultsOnReturn() async throws {
        let catalog = ControlledCardCatalog(), model = ManualCardSearchModel(game: "Pokémon", catalog: catalog, debounce: .zero)
        model.updateQuery("darkrai"); try await requests(1, catalog); model.cancel()
        await catalog.resolve(0, with: [card(1)])
        for _ in 0..<15 { await Task.yield() }
        XCTAssertTrue(model.results.isEmpty); XCTAssertFalse(model.isSearching)
    }
    func testManualSelectionDefaultsToNMAndOnlyExplicitAddPersistsExactZeroQuote() async throws {
        let container = try store(), context = container.mainContext, list = CardList(name: "Manual")
        context.insert(list); try context.save()
        var candidate = card(99); candidate.identity.condition = "Damaged"; candidate.marketPrice = 999; candidate.identity.skuID = "999"
        let model = ManualCardAddModel(card: candidate, pricing: ExactManualPricing())
        XCTAssertEqual(model.pricing.card.identity.condition, "Near Mint"); XCTAssertNil(model.pricing.card.marketPrice)
        XCTAssertEqual(list.quantity, 0)
        model.pricing.changeIdentity { $0.condition = "Lightly Played" }
        await priceIdle(model.pricing)
        XCTAssertEqual(model.pricing.card.marketPrice, 0); XCTAssertEqual(model.pricing.card.identity.skuID, "222")
        XCTAssertEqual(list.quantity, 0)
        XCTAssertTrue(model.add(to: list, context: context)); XCTAssertFalse(model.add(to: list, context: context))
        XCTAssertEqual(list.quantity, 1); XCTAssertEqual(list.orderedCards[0].snapshot.marketPrice, 0)
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.condition, "Lightly Played")
        XCTAssertEqual(list.orderedCards[0].snapshot.identity.skuID, "222"); XCTAssertEqual(list.unpricedQuantity, 0)
        let next = ManualCardAddModel(card: candidate, pricing: ExactManualPricing())
        XCTAssertTrue(next.add(to: list, context: context)); XCTAssertEqual(list.cards.count, 2)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1]); XCTAssertNotEqual(list.orderedCards[0].id, list.orderedCards[1].id)
        XCTAssertEqual(next.pricing.card.identity.condition, "Near Mint")
    }
    func testManualAddConfirmsSessionSwitchAndPreservesExistingListAndOffers() async throws {
        let container = try store(), context = container.mainContext
        let session = try SessionService.start(game: "Pokémon", context: context)
        let list = try XCTUnwrap(SessionService.list(for: session, context: context))
        try SessionService.add(card(1), session: session, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context)
        let offers = session.savedOffersData, identity = session.id
        try SessionService.finish(session, context: context)
        let other = try SessionService.start(game: "Pokémon", context: context)
        let model = ManualCardAddModel(card: card(99), pricing: ExactManualPricing())
        XCTAssertFalse(model.add(to: list, context: context)); XCTAssertTrue(model.needsSessionSwitch)
        XCTAssertTrue(other.isActive); XCTAssertFalse(session.isActive); XCTAssertEqual(list.quantity, 1)
        XCTAssertTrue(model.add(to: list, context: context, finishingOtherSession: true))
        XCTAssertEqual(session.id, identity); XCTAssertTrue(session.isActive); XCTAssertFalse(other.isActive)
        XCTAssertEqual(session.savedOffersData, offers); XCTAssertEqual(list.quantity, 2)
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.productID }, ["p:1", "p:99"])
    }
    func testUnavailableOnlineQuoteCanOnlyBeSavedAsExplicitlyUnpriced() async throws {
        let container = try store(), context = container.mainContext, list = CardList(name: "Offline")
        context.insert(list); try context.save()
        var candidate = card(99); candidate.marketPrice = 999; candidate.identity.skuID = "999"
        let model = ManualCardAddModel(card: candidate, pricing: UnavailableManualPricing())
        model.pricing.refreshPrice(); await priceIdle(model.pricing)
        XCTAssertNil(model.pricing.card.marketPrice); XCTAssertNil(model.pricing.card.identity.skuID)
        XCTAssertTrue(model.pricing.priceMessage?.contains("without a market value") == true)
        XCTAssertEqual(list.quantity, 0)
        XCTAssertTrue(model.add(to: list, context: context)); XCTAssertEqual(list.quantity, 1)
        XCTAssertNil(list.orderedCards[0].snapshot.marketPrice); XCTAssertEqual(list.unpricedQuantity, 1)
    }
    func testManualAddFailureRetainsSelectionsAndRetryAddsOnlyOneRow() async throws {
        let container = try store(), context = container.mainContext, list = CardList(name: "Retry")
        context.insert(list); try context.save()
        var calls = 0
        let model = ManualCardAddModel(card: card(99), pricing: ExactManualPricing(), saveCard: { card, session, list, context in
            calls += 1
            if calls == 1 {
                try CardListService.add(card, to: list, context: context); session.record(card)
                throw URLError(.cannotWriteToFile)
            }
            try SessionService.add(card, session: session, list: list, context: context)
        })
        model.pricing.changeIdentity { $0.condition = "Lightly Played" }; await priceIdle(model.pricing)
        XCTAssertFalse(model.add(to: list, context: context)); XCTAssertFalse(model.isSaved); XCTAssertNotNil(model.error)
        XCTAssertEqual(list.quantity, 0); XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 0)
        XCTAssertEqual(model.pricing.card.identity.condition, "Lightly Played"); XCTAssertEqual(model.pricing.card.identity.skuID, "222")
        XCTAssertTrue(model.add(to: list, context: context)); XCTAssertTrue(model.isSaved); XCTAssertNil(model.error)
        XCTAssertEqual(list.quantity, 1); XCTAssertEqual(calls, 2)
    }

    private func card(_ id: Int) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:\(id)", printing: "Normal"),
            name: "Darkrai", set: "Triumphant", number: "\(id)/102", confidence: 0, printings: ["Normal"])
    }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func requests(_ count: Int, _ catalog: ControlledCardCatalog) async throws {
        for _ in 0..<100 {
            let value = await catalog.count
            if value >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not start"); throw URLError(.timedOut)
    }
    private func idle(_ model: ManualCardSearchModel) async {
        for _ in 0..<100 { if !model.isSearching { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Search did not finish")
    }
    private func priceIdle(_ model: CardEditorPricingModel) async {
        for _ in 0..<100 { if !model.priceLoading { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Price did not finish")
    }
}

private actor ControlledCardCatalog: CardCatalogSearching {
    var count: Int { pending.count }
    private var pending: [CheckedContinuation<[CardCandidate], Error>?] = []
    func search(_ query: String, game: String, limit: Int) async throws -> [CardCandidate] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, with value: [CardCandidate]) { let item = pending[index]; pending[index] = nil; item?.resume(returning: value) }
}
private struct ExactManualPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        MarketQuote(marketPrice: card.identity.condition == "Near Mint" ? 10 : 0, skuID: card.identity.condition == "Near Mint" ? "111" : "222")
    }
}
private struct UnavailableManualPricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { throw URLError(.notConnectedToInternet) }
}
