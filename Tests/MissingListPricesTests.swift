import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class MissingListPricesTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let list: CardList
        let other: CardList
        let rows: [InventoryCard]
    }

    private func card(_ id: Int, price: Decimal? = nil) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: "p:\(id)", skuID: "old-sku", printing: "Normal"),
            name: "Synthetic \(id)", set: "Fixture", number: String(id), marketPrice: price,
            confidence: 95, printings: ["Normal", "Reverse Holofoil"])
    }

    private func fixture(_ prices: [Decimal?] = [nil, nil]) throws -> Fixture {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = CardList(name: "Price recovery"), other = CardList(name: "Unrelated saved list")
        context.insert(list); context.insert(other)
        var rows: [InventoryCard] = []
        for (index, price) in prices.enumerated() {
            let row = try InventoryCard(card: card(index + 1, price: price), quantity: index == 0 ? 2 : 1)
            row.addedAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            row.cashOverrideText = "1.25"; row.tradeOverrideText = "2"; row.maximumOverrideText = "1"
            context.insert(row); list.cards.append(row); rows.append(row)
        }
        try context.save()
        return Fixture(container: container, context: context, list: list, other: other, rows: rows)
    }

    private func requests(_ count: Int, _ pricing: MissingPricesGate, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            let observed = await pricing.requests.count
            if observed >= count { return }
            await Task.yield()
        }
        XCTFail("Expected pricing request \(count)", file: file, line: line)
    }

    private func details(_ price: Decimal?, sku: String = "new-sku") -> MarketDetails {
        MarketDetails(quote: price.map { MarketQuote(marketPrice: $0, skuID: sku) },
            metadata: MarketPriceMetadata(source: .openAPI, fetchedAt: Date(timeIntervalSince1970: 1_800_000_001), isCached: true))
    }

    private func persisted(_ fixture: Fixture, rowID: UUID) throws -> InventoryCard? {
        try ModelContext(fixture.container).fetch(FetchDescriptor<InventoryCard>(predicate: #Predicate { $0.id == rowID })).first
    }

    func testSerialCacheRespectingRefreshUpdatesVisibleAndSavedRowsWithoutChangingStockOrKnownPrices() async throws {
        let f = try fixture([nil, 0, 7, nil]), pricing = MissingPricesGate()
        let original = f.rows.map { ($0.id, $0.data, $0.quantity, $0.addedAt, $0.cashOverrideText, $0.tradeOverrideText, $0.maximumOverrideText) }
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertTrue(model.start(list: f.list, context: f.context))
        XCTAssertFalse(model.start(list: f.list, context: f.context), "A second tap cannot start another pass")
        await requests(1, pricing)
        let inFlight = await pricing.requests.count
        XCTAssertEqual(inFlight, 1, "Only one quote may be in flight")
        await pricing.resolve(0, .success(details(Decimal(string: "3.25"))))
        await requests(2, pricing)
        XCTAssertEqual(f.rows[0].snapshot.marketPrice, Decimal(string: "3.25"), "The presenting row updates immediately")
        XCTAssertEqual(f.list.knownValue, Decimal(string: "13.50"), "Visible totals use the saved repaired price")
        await pricing.resolve(1, .success(details(0, sku: "zero-sku")))
        await model.waitUntilFinished()

        let sent = await pricing.requests
        XCTAssertEqual(sent.map { $0.card.identity.productID }, ["p:1", "p:4"])
        XCTAssertEqual(sent.map(\.forceRefresh), [false, false])
        XCTAssertEqual(model.total, 2); XCTAssertEqual(model.completed, 2); XCTAssertEqual(model.updated, 2)
        XCTAssertEqual(model.remaining, 0); XCTAssertEqual(model.progress, 1)
        XCTAssertFalse(model.isRunning); XCTAssertNil(model.error); XCTAssertFalse(f.context.hasChanges)
        XCTAssertEqual(f.list.orderedCards.map(\.id), original.map { $0.0 })
        for (index, row) in f.rows.enumerated() {
            XCTAssertEqual(row.quantity, original[index].2); XCTAssertEqual(row.addedAt, original[index].3)
            XCTAssertEqual(row.cashOverrideText, original[index].4); XCTAssertEqual(row.tradeOverrideText, original[index].5)
            XCTAssertEqual(row.maximumOverrideText, original[index].6)
            if index == 1 || index == 2 { XCTAssertEqual(row.data, original[index].1) }
        }
        let stored = try XCTUnwrap(persisted(f, rowID: f.rows[0].id))
        XCTAssertEqual(stored.snapshot, f.rows[0].snapshot)
        XCTAssertEqual(stored.snapshot.identity.skuID, "new-sku")
        XCTAssertEqual(stored.snapshot.marketPriceMetadata, details(3).metadata)
        XCTAssertEqual(stored.snapshot.identity.condition, "Near Mint")
        XCTAssertEqual(stored.snapshot.printings, ["Normal", "Reverse Holofoil"])
    }

    func testPartialResultsKeepUnavailableAndFailedRowsUnchanged() async throws {
        let f = try fixture([nil, nil, nil]), pricing = MissingPricesGate()
        let original = f.rows.map(\.data)
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        await pricing.resolve(0, .success(details(nil))); await requests(2, pricing)
        await pricing.resolve(1, .failure(URLError(.notConnectedToInternet))); await requests(3, pricing)
        await pricing.resolve(2, .success(details(5))); await model.waitUntilFinished()
        XCTAssertEqual(model.completed, 3); XCTAssertEqual(model.updated, 1)
        XCTAssertEqual(model.unavailable, 1); XCTAssertEqual(model.failed, 1); XCTAssertEqual(model.remaining, 2)
        XCTAssertEqual(f.rows[0].data, original[0]); XCTAssertEqual(f.rows[1].data, original[1])
        XCTAssertTrue(try XCTUnwrap(model.summary).contains("1 lookups or saves failed"))
        XCTAssertNil(model.error)
    }

    func testUnrelatedUnsavedEditsPreventStartingWithoutSavingOrDiscardingThem() async throws {
        let f = try fixture(), pricing = MissingPricesGate()
        f.other.name = "Unsaved draft"
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertFalse(model.start(list: f.list, context: f.context))
        XCTAssertTrue(f.context.hasChanges); XCTAssertEqual(f.other.name, "Unsaved draft")
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Finish saving"))
        let requestCount = await pricing.requests.count
        XCTAssertEqual(requestCount, 0)
        let saved = try ModelContext(f.container).fetch(FetchDescriptor<CardList>()).first { $0.id == f.other.id }
        XCTAssertEqual(saved?.name, "Unrelated saved list")
    }

    func testEditsMadeDuringLookupStopThePassWithoutImplicitlyCommittingThem() async throws {
        let f = try fixture(), pricing = MissingPricesGate(), original = f.rows[0].data
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        f.other.name = "Keep this edit unsaved"
        await pricing.resolve(0, .success(details(10))); await model.waitUntilFinished()
        XCTAssertEqual(model.updated, 0); XCTAssertEqual(f.rows[0].data, original)
        XCTAssertTrue(f.context.hasChanges); XCTAssertEqual(f.other.name, "Keep this edit unsaved")
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Finish saving"))
        XCTAssertNil(try persisted(f, rowID: f.rows[0].id)?.snapshot.marketPrice)
        let requestCount = await pricing.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testChangedKnownPriceAndIdentityRepliesAreSkippedRatherThanOverwritten() async throws {
        for makeKnown in [false, true] {
            let f = try fixture([nil]), pricing = MissingPricesGate()
            let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
            XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
            var changed = f.rows[0].snapshot
            if makeKnown { changed.marketPrice = 99 }
            else { changed.identity.condition = "Lightly Played" }
            try f.rows[0].update(changed); try f.context.save()
            await pricing.resolve(0, .success(details(1))); await model.waitUntilFinished()
            XCTAssertEqual(model.updated, 0); XCTAssertEqual(model.skipped, 1)
            XCTAssertEqual(f.rows[0].snapshot, changed)
            XCTAssertEqual(try persisted(f, rowID: f.rows[0].id)?.snapshot, changed)
        }
    }

    func testExternalSavedPriceAndDeletedRowsCannotBeRestoredByLateQuotes() async throws {
        for delete in [false, true] {
            let f = try fixture([nil]), pricing = MissingPricesGate(), rowID = f.rows[0].id
            let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
            XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
            let writer = ModelContext(f.container)
            let row = try XCTUnwrap(writer.fetch(FetchDescriptor<InventoryCard>(predicate: #Predicate { $0.id == rowID })).first)
            if delete { writer.delete(row) }
            else { var changed = row.snapshot; changed.marketPrice = 42; try row.update(changed) }
            try writer.save()
            await pricing.resolve(0, .success(details(1))); await model.waitUntilFinished()
            XCTAssertEqual(model.updated, 0)
            if delete { XCTAssertNil(try persisted(f, rowID: rowID)) }
            else { XCTAssertEqual(try persisted(f, rowID: rowID)?.snapshot.marketPrice, 42) }
        }
    }

    func testDeletingTheListDuringLookupCannotRecreateIt() async throws {
        let f = try fixture([nil]), pricing = MissingPricesGate(), listID = f.list.id
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        f.context.delete(f.list); try f.context.save()
        await pricing.resolve(0, .success(details(1))); await model.waitUntilFinished()
        XCTAssertEqual(model.updated, 0)
        let saved = try ModelContext(f.container).fetch(FetchDescriptor<CardList>(predicate: #Predicate { $0.id == listID }))
        XCTAssertTrue(saved.isEmpty)
    }

    func testCancelledReplyCannotEnterTheNextPass() async throws {
        let f = try fixture([nil]), pricing = MissingPricesGate()
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        model.cancel(); XCTAssertTrue(model.wasCancelled); XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(2, pricing)
        await pricing.resolve(0, .success(details(99, sku: "retired")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.isRunning); XCTAssertEqual(model.updated, 0); XCTAssertNil(f.rows[0].snapshot.marketPrice)
        await pricing.resolve(1, .success(details(4, sku: "current"))); await model.waitUntilFinished()
        XCTAssertEqual(model.updated, 1); XCTAssertEqual(f.rows[0].snapshot.marketPrice, 4)
        XCTAssertEqual(f.rows[0].snapshot.identity.skuID, "current")
    }

    func testCoolingStopsFurtherWorkAndKeepsAlreadySavedPrices() async throws {
        let f = try fixture(), pricing = MissingPricesGate(), thermal = MissingPricesThermalGate()
        let model = MissingListPricesModel(pricing: pricing, canContinue: { thermal.allowsWork })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        await pricing.resolve(0, .success(details(3))); await requests(2, pricing)
        thermal.allowsWork = false
        await pricing.resolve(1, .success(details(9))); await model.waitUntilFinished()
        XCTAssertTrue(model.pausedForCooling); XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.updated, 1); XCTAssertEqual(model.remaining, 1)
        XCTAssertEqual(f.rows[0].snapshot.marketPrice, 3); XCTAssertNil(f.rows[1].snapshot.marketPrice)
        XCTAssertTrue(try XCTUnwrap(model.summary).contains("cool"))
    }

    func testFailedSaveRestoresOnlyItsPriceFieldAndStopsWithoutRollback() async throws {
        let f = try fixture(), pricing = MissingPricesGate(), original = f.rows[0].data
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true }, save: { _ in
            f.other.name = "An unrelated observer draft"
            throw URLError(.cannotWriteToFile)
        })
        XCTAssertTrue(model.start(list: f.list, context: f.context)); await requests(1, pricing)
        await pricing.resolve(0, .success(details(8))); await model.waitUntilFinished()
        XCTAssertEqual(model.updated, 0); XCTAssertEqual(model.failed, 1); XCTAssertNotNil(model.error)
        XCTAssertEqual(f.rows[0].data, original); XCTAssertEqual(f.other.name, "An unrelated observer draft")
        XCTAssertTrue(f.context.hasChanges)
        XCTAssertNil(try persisted(f, rowID: f.rows[0].id)?.snapshot.marketPrice)
        let requestCount = await pricing.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testImportedInventoryAndImportedRowsRemainReadOnly() async throws {
        let f = try fixture([nil]), pricing = MissingPricesGate()
        let model = MissingListPricesModel(pricing: pricing, canContinue: { true })
        f.list.inventorySourceData = Data([1]); try f.context.save()
        XCTAssertFalse(model.start(list: f.list, context: f.context)); XCTAssertNotNil(model.error)
        f.list.inventorySourceData = nil; f.rows[0].sourceInventoryID = 7; try f.context.save()
        XCTAssertFalse(model.start(list: f.list, context: f.context)); XCTAssertEqual(model.total, 0)
        let requestCount = await pricing.requests.count
        XCTAssertEqual(requestCount, 0); XCTAssertNil(f.rows[0].snapshot.marketPrice)
    }
}

private actor MissingPricesGate: MarketPricing {
    struct Request: Sendable { let card: CardCandidate; let forceRefresh: Bool }
    private(set) var requests: [Request] = []
    private var waiting: [Int: CheckedContinuation<MarketDetails, Error>] = [:]
    func quote(for card: CardCandidate) async throws -> MarketQuote? { nil }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        let index = requests.count
        requests.append(Request(card: card, forceRefresh: forceRefresh))
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func resolve(_ index: Int, _ result: Result<MarketDetails, Error>) { waiting.removeValue(forKey: index)?.resume(with: result) }
}

@MainActor private final class MissingPricesThermalGate { var allowsWork = true }
