import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class LeftoverStockModelTests: XCTestCase {
    private final class Disk { var data: Data? }
    private func savedStore() -> LeftoverStockStore {
        let disk = Disk()
        return LeftoverStockStore(read: { _ in disk.data }, write: { data, _ in disk.data = data })
    }
    private func container() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func card(_ product: String = "42", sku: String? = "4200", game: String = "Pokémon") -> CardCandidate {
        CardCandidate(identity: .init(game: game, productID: product, skuID: sku, printing: "Normal"),
            name: "Fixture " + product, set: "Fixture set", number: product, marketPrice: nil,
            confidence: 100, printings: ["Normal"])
    }
    private func snapshot(_ rows: [(CardCandidate, Int)]? = nil) -> CardShowInventorySnapshot {
        .init(location: .init(id: 9123, name: "Card Show"), rows: (rows ?? [(card(), 3)]).enumerated().map {
            .init(inventoryID: $0.offset + 1, card: $0.element.0, quantity: $0.element.1)
        }, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    @discardableResult private func list(_ rows: [(CardCandidate, Int)], context: ModelContext) throws -> CardList {
        let list = CardList(name: "Independent count")
        context.insert(list)
        for (card, quantity) in rows {
            let item = try InventoryCard(card: card, quantity: quantity)
            context.insert(item); list.cards.append(item)
        }
        try context.save()
        return list
    }

    func testStartFreezesWebsiteSnapshotWithoutImportingFinancialInventory() async throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let unrelated = try list([(card("99", sku: "9900"), 11)], context: context)
        let provider = LeftoverModelProvider(snapshot: snapshot())
        let model = LeftoverStockModel(store: store, provider: provider)
        await model.startNewCount(context: context)
        XCTAssertEqual(provider.expectedLocations.count, 1); XCTAssertNil(provider.expectedLocations[0])
        XCTAssertEqual(model.session?.baseline.rows.first?.quantity, 3)
        XCTAssertEqual(model.comparison?.countedQuantity, 0)
        XCTAssertEqual(unrelated.quantity, 11)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CardList>()).count, 1)
        let resumed = LeftoverStockModel(store: store, provider: provider)
        resumed.refresh(context: context)
        XCTAssertEqual(provider.expectedLocations.count, 1)
        XCTAssertEqual(resumed.comparison?.baselineQuantity, 3)
        XCTAssertFalse(resumed.isComplete)
    }

    func testEmptyScanKeepsOnlyPendingSidecarReferenceAndCreatesNoList() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        try store.start(baseline: .init(snapshot: snapshot()))
        let model = LeftoverStockModel(store: store)
        let route = try model.prepareScan(context: context)
        XCTAssertEqual(store.active?.countListIDs, [route.list.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).isEmpty)
        XCTAssertFalse(try XCTUnwrap(route.draft).isCommitted)
        model.scanClosed(route, context: context)
        XCTAssertEqual(store.active?.countListIDs, [])
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).isEmpty)
    }

    func testFirstConfirmedCardPromotesDraftAndNextScanResumesSavedCount() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        try store.start(baseline: .init(snapshot: snapshot()))
        let model = LeftoverStockModel(store: store)
        let route = try model.prepareScan(context: context)
        let draft = try XCTUnwrap(route.draft)
        try SessionService.commitDraft(draft, card: card(), context: context)
        XCTAssertTrue(draft.isCommitted)
        XCTAssertFalse(draft.list === route.list)
        model.scanClosed(route, context: context)
        XCTAssertEqual(model.comparison?.countedQuantity, 1)
        XCTAssertEqual(store.active?.countListIDs, [draft.list.id])
        let resumed = try model.prepareScan(context: context)
        XCTAssertNil(resumed.draft)
        XCTAssertEqual(resumed.list.id, draft.list.id)
        XCTAssertEqual(resumed.list.quantity, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CardList>()).count, 1)
    }

    func testManualCountCoversUnsupportedGameAndExportsAbsoluteStockAcrossAllGames() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        try store.start(baseline: .init(snapshot: snapshot([(card(), 9), (card("81", sku: "8100", game: "Card Sleeves"), 4)])))
        let model = LeftoverStockModel(store: store)
        model.refresh(context: context)
        let pokemon = try XCTUnwrap(model.comparison?.rows.first { $0.skuID == "4200" })
        try model.setCount(2, for: pokemon, context: context)
        let sleeves = try XCTUnwrap(model.comparison?.rows.first { $0.skuID == "8100" })
        try model.setCount(1, for: sleeves, context: context)
        model.selectedGame = "Card Sleeves"
        XCTAssertFalse(model.canScanSelectedGame)
        XCTAssertEqual(model.comparison?.countedQuantity, 3)
        XCTAssertThrowsError(try model.replacementCSV(context: context))
        try model.finishCount(context: context)
        let csv = try model.replacementCSV(context: context)
        XCTAssertTrue(csv.contains("4200")); XCTAssertTrue(csv.contains("8100"))
        XCTAssertFalse(csv.contains("marketPrice")); XCTAssertFalse(csv.contains(",9,"))
        XCTAssertEqual(model.lists.count, 2); XCTAssertTrue(model.isComplete)
    }

    func testMissingCountReferenceBlocksCompletionUntilExplicitlyRemoved() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let session = try store.start(baseline: .init(snapshot: snapshot()))
        try store.addCountList(id: UUID(), sessionID: session.id)
        let model = LeftoverStockModel(store: store)
        model.refresh(context: context)
        XCTAssertEqual(model.missingListIDs.count, 1)
        XCTAssertThrowsError(try model.finishCount(context: context))
        XCTAssertThrowsError(try model.comparisonCSV(context: context))
        try model.removeMissingReferences(context: context)
        try model.finishCount(context: context)
        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(try model.replacementCSV(context: context).components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).isEmpty)
    }

    func testUnsavedAndLaterSavedEditsBothBlockPreviouslyCompletedExport() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let session = try store.start(baseline: .init(snapshot: snapshot()))
        let counted = try list([(card(), 1)], context: context)
        try store.addCountList(id: counted.id, sessionID: session.id)
        let model = LeftoverStockModel(store: store)
        try model.finishCount(context: context)
        let item = try XCTUnwrap(counted.cards.first)
        item.quantity = 2
        XCTAssertThrowsError(try model.replacementCSV(context: context))
        XCTAssertTrue(context.hasChanges)
        try context.save()
        XCTAssertThrowsError(try model.replacementCSV(context: context))
        XCTAssertFalse(model.isComplete)
        try model.finishCount(context: context)
        XCTAssertNoThrow(try model.replacementCSV(context: context))
    }

    func testFailedFetchCannotExportCachedCountOrMarkItComplete() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        try store.start(baseline: .init(snapshot: snapshot()))
        var fail = false
        let model = LeftoverStockModel(store: store, fetchLists: {
            if fail { throw CocoaError(.fileReadUnknown) }
            return try $0.fetch(FetchDescriptor<CardList>())
        })
        try model.finishCount(context: context)
        XCTAssertTrue(model.isComplete)
        fail = true
        XCTAssertThrowsError(try model.replacementCSV(context: context))
        XCTAssertFalse(model.countAvailable); XCTAssertFalse(model.canExportReplacement)
        XCTAssertThrowsError(try model.finishCount(context: context))
    }

    func testAbsoluteCorrectionSaveFailurePreservesRowsAndQuantities() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let session = try store.start(baseline: .init(snapshot: snapshot()))
        let counted = try list([(card(), 1), (card(), 2)], context: context)
        try store.addCountList(id: counted.id, sessionID: session.id)
        let originalIDs = Set(counted.cards.map(\.id))
        let model = LeftoverStockModel(store: store, saveCount: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        model.refresh(context: context)
        let row = try XCTUnwrap(model.comparison?.rows.first)
        XCTAssertThrowsError(try model.setCount(4, for: row, context: context))
        XCTAssertEqual(Set(counted.cards.map(\.id)), originalIDs)
        XCTAssertEqual(counted.cards.map(\.quantity).sorted(), [1, 2])
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(model.comparison?.countedQuantity, 3)
    }

    func testSourceBackedListCannotBeMutatedThroughDamagedCountReference() throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let session = try store.start(baseline: .init(snapshot: snapshot()))
        let source = try list([(card(), 9)], context: context)
        source.cards.first?.sourceInventoryID = 5
        try context.save(); try store.addCountList(id: source.id, sessionID: session.id)
        let model = LeftoverStockModel(store: store)
        model.refresh(context: context)
        XCTAssertFalse(model.countAvailable)
        XCTAssertThrowsError(try model.finishCount(context: context))
        XCTAssertEqual(source.quantity, 9)
    }

    func testSKUResolutionUsesExactQuoteWithoutRequiringOrChangingPrice() async throws {
        let container = try container(), context = container.mainContext, store = savedStore()
        let session = try store.start(baseline: .init(snapshot: snapshot([])))
        let counted = try list([(card("77", sku: nil), 2)], context: context)
        try store.addCountList(id: counted.id, sessionID: session.id)
        let model = LeftoverStockModel(store: store, pricing: LeftoverSKUPrice())
        model.refresh(context: context)
        XCTAssertFalse(try XCTUnwrap(model.comparison).canExport)
        await model.resolveMissingSKUs(context: context)
        XCTAssertEqual(counted.cards.first?.snapshot.identity.skuID, "7700")
        XCTAssertNil(counted.cards.first?.snapshot.marketPrice)
        XCTAssertEqual(counted.quantity, 2)
        XCTAssertTrue(try XCTUnwrap(model.comparison).canExport)
        try model.finishCount(context: context)
        XCTAssertTrue(try model.replacementCSV(context: context).contains("7700"))
    }

    func testCanceledBaselineReplyCannotStartCount() async throws {
        let container = try container(), store = savedStore()
        let provider = LeftoverModelProvider(snapshot: snapshot(), hold: true)
        let model = LeftoverStockModel(store: store, provider: provider)
        let task = Task { await model.startNewCount(context: container.mainContext) }
        for _ in 0..<100 where provider.pending == nil { await Task.yield() }
        XCTAssertNotNil(provider.pending)
        model.cancel(); provider.finish()
        await task.value
        XCTAssertNil(model.session); XCTAssertFalse(model.isFetching)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<CardList>()).isEmpty)
    }
}

@MainActor private final class LeftoverModelProvider: CardShowInventoryProviding {
    let snapshot: CardShowInventorySnapshot
    let hold: Bool
    var expectedLocations: [Int?] = []
    var pending: CheckedContinuation<CardShowInventorySnapshot, Error>?
    init(snapshot: CardShowInventorySnapshot, hold: Bool = false) { self.snapshot = snapshot; self.hold = hold }
    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot {
        expectedLocations.append(expectedLocationID)
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return snapshot
    }
    func finish() { pending?.resume(returning: snapshot); pending = nil }
    func cancel() {}
}

private struct LeftoverSKUPrice: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? { .init(marketPrice: nil, skuID: "7700") }
}
