import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ScannerQuickActionTests: XCTestCase {
    private enum InjectedActionFailure: Error { case writeRefused }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func batch(_ context: ModelContext) throws -> (ScanSession, CardList) {
        let session = try SessionService.start(game: "Pokémon", context: context)
        return (session, try XCTUnwrap(SessionService.list(for: session, context: context)))
    }
    private func card(_ id: Int, name: String? = nil) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:\(id)", printing: "Normal"),
                      name: name ?? "Card \(id)", set: "Quick action fixtures", number: "\(id)/200",
                      marketPrice: nil, confidence: 96, printings: ["Normal", "Holofoil", "Reverse Holofoil"])
    }
    private func waitForIdle(_ model: ScannerViewModel) async throws {
        for _ in 0..<200 {
            if !model.priceLoading && !model.selectionInProgress { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The scanner did not finish the selected card")
        throw URLError(.timedOut)
    }
    private func waitForQuickActions(_ model: ScannerViewModel) async throws {
        for _ in 0..<200 {
            if model.canAddAnotherCopy && model.canUndoLastAdd { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The saved card did not become available for a quick action")
        throw URLError(.timedOut)
    }
    @discardableResult private func confirm(_ card: CardCandidate, model: ScannerViewModel,
                                           list: CardList, context: ModelContext, episode: UUID = UUID()) async throws -> InventoryCard {
        model.receive(ScanResult(id: episode, candidates: [card], accepted: true, same: false))
        try await waitForIdle(model)
        model.selectAndAdd(card, list: list, context: context)
        try await waitForIdle(model)
        XCTAssertNil(model.selected)
        return try XCTUnwrap(list.orderedCards.last)
    }

    func testCopyUsesConfirmedPrintingConditionAndQuoteWithoutPricingOrCameraRestart() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let provider = QuickActionScannerProvider()
        let pricing = QuickActionPricing(quote: MarketQuote(marketPrice: Decimal(string: "2.35"), skuID: "98765"))
        let model = ScannerViewModel(provider: provider, pricing: pricing, quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = card(101)
        model.receive(ScanResult(id: UUID(), candidates: [original], accepted: true, same: false))
        model.changeCondition("Lightly Played"); model.changePrinting("Holofoil")
        try await waitForIdle(model)
        model.selectAndAdd(original, list: list, context: context)
        try await waitForIdle(model)
        let first = try XCTUnwrap(list.orderedCards.first)
        let confirmed = first.snapshot
        XCTAssertEqual(confirmed.identity.printing, "Holofoil")
        XCTAssertEqual(confirmed.identity.condition, "Lightly Played")
        XCTAssertEqual(confirmed.identity.skuID, "98765")
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 3)
        let offers = session.savedOffersData
        let requests = await pricing.count
        let starts = provider.starts, stops = provider.stops
        await pricing.replaceQuote(MarketQuote(marketPrice: 999, skuID: "unrelated-new-quote"))

        model.addAnotherCopy(list: list, context: context)

        XCTAssertEqual(list.orderedCards.count, 2)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1])
        XCTAssertEqual(list.orderedCards.map(\.snapshot), [confirmed, confirmed])
        XCTAssertNotEqual(list.orderedCards[0].id, list.orderedCards[1].id)
        XCTAssertLessThan(list.orderedCards[0].addedAt, list.orderedCards[1].addedAt)
        XCTAssertEqual(session.addedQuantity, 2)
        XCTAssertEqual(session.knownValue, Decimal(string: "4.70"))
        XCTAssertEqual(session.savedOffersData, offers)
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.lastAddedCard, confirmed)
        let requestsAfterCopy = await pricing.count
        XCTAssertEqual(requestsAfterCopy, requests)
        XCTAssertEqual(provider.starts, starts); XCTAssertEqual(provider.stops, stops)
    }

    func testCopyPreservesKnownZeroAndUnavailablePricesAsDifferentStates() async throws {
        let prices: [Decimal?] = [Decimal.zero, nil]
        for price in prices {
            let container = try store(), context = container.mainContext
            let (session, list) = try batch(context)
            let pricing = QuickActionPricing(quote: MarketQuote(marketPrice: price, skuID: "1234"))
            let model = ScannerViewModel(provider: QuickActionScannerProvider(), pricing: pricing, quickActionCooldown: .zero)
            model.start(game: "Pokémon", list: list, context: context, session: session)
            defer { model.stop() }
            try await confirm(card(102), model: model, list: list, context: context)
            model.addAnotherCopy(list: list, context: context)
            XCTAssertEqual(list.orderedCards.map { $0.snapshot.marketPrice }, [price, price])
            XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.skuID }, ["1234", "1234"])
            XCTAssertEqual(session.knownValue, 0)
            XCTAssertEqual(session.unpricedQuantity, price == nil ? 2 : 0)
        }
    }

    func testUndoRestoresFrozenCandidatesAndSelectionsForCorrection() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let pricing = QuickActionPricing(quote: MarketQuote(marketPrice: 2, skuID: "22"))
        let model = ScannerViewModel(provider: QuickActionScannerProvider(), pricing: pricing, quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let prior = try await confirm(card(101), model: model, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context)
        let offers = session.savedOffersData
        let candidates = [card(102), card(103)]
        let frozen = ScanResult(id: UUID(), candidates: candidates, accepted: true, same: false,
                                capturedImageData: Data([1, 2, 3]))
        model.receive(frozen)
        model.changeCondition("Moderately Played"); model.changePrinting("Reverse Holofoil")
        try await waitForIdle(model)
        model.selectAndAdd(candidates[0], list: list, context: context)
        try await waitForIdle(model)
        let savedIdentity = try XCTUnwrap(list.orderedCards.last).snapshot.identity
        XCTAssertEqual(list.quantity, 2)

        model.undoLastAdd(list: list, context: context)
        try await waitForIdle(model)

        XCTAssertEqual(list.orderedCards.map(\.id), [prior.id])
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, 2)
        XCTAssertEqual(session.savedOffersData, offers)
        XCTAssertEqual(model.result?.id, frozen.id)
        XCTAssertEqual(model.result?.candidates, frozen.candidates)
        XCTAssertEqual(model.selected?.identity.productID, savedIdentity.productID)
        XCTAssertEqual(model.selected?.identity.printing, "Reverse Holofoil")
        XCTAssertEqual(model.selected?.identity.condition, "Moderately Played")
        XCTAssertFalse(model.canAddAnotherCopy, "A restored review must not be bypassed by copying a prior row")
        XCTAssertFalse(model.canUndoLastAdd)
        XCTAssertEqual(list.quantity, 1, "Restoring a review does not save it")
        model.selectAndAdd(candidates[1], list: list, context: context)
        try await waitForIdle(model)
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.productID }, ["p:101", "p:103"])
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1])
        XCTAssertEqual(list.orderedCards.last?.snapshot.identity.condition, "Moderately Played")
    }

    func testUndoCopyRemovesOnlyTheCopyAndStaysReadyForAnotherCard() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: nil, skuID: "555")),
                                     quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = try await confirm(card(101), model: model, list: list, context: context)
        model.addAnotherCopy(list: list, context: context)
        let copy = try XCTUnwrap(list.orderedCards.last)
        XCTAssertNotEqual(copy.id, original.id)
        model.undoLastAdd(list: list, context: context)
        XCTAssertEqual(list.orderedCards.map(\.id), [original.id])
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.unpricedQuantity, 1)
        XCTAssertNil(model.selected); XCTAssertNil(model.result)
        XCTAssertEqual(model.lastAddedCard, original.snapshot)
        XCTAssertTrue(model.canAddAnotherCopy)
        XCTAssertTrue(model.canUndoLastAdd)
    }

    func testRapidRepeatedCopyTapAddsOneCopyAndLaterExplicitTapAddsAnother() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 1, skuID: "1")),
                                     quickActionCooldown: .milliseconds(50))
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        try await confirm(card(101), model: model, list: list, context: context)
        try await waitForQuickActions(model)
        model.addAnotherCopy(list: list, context: context)
        model.addAnotherCopy(list: list, context: context)
        XCTAssertEqual(list.quantity, 2, "A double tap must not create two copies")
        XCTAssertFalse(model.canAddAnotherCopy)
        try await waitForQuickActions(model)
        model.addAnotherCopy(list: list, context: context)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1, 1])
        XCTAssertEqual(Set(list.orderedCards.map(\.id)).count, 3)
    }

    func testRapidRepeatedUndoOfCopyCannotRemoveTheOriginalRow() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 1, skuID: "1")),
                                     quickActionCooldown: .milliseconds(50))
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = try await confirm(card(101), model: model, list: list, context: context)
        let originalID = original.id
        try await waitForQuickActions(model)
        model.addAnotherCopy(list: list, context: context)
        try await waitForQuickActions(model)

        model.undoLastAdd(list: list, context: context)
        model.undoLastAdd(list: list, context: context)

        XCTAssertEqual(list.orderedCards.map(\.id), [originalID], "A double Undo tap must remove only the added copy")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 1)
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, 1)
        XCTAssertNil(model.selected, "Undoing the copy must not reopen the original review")
        XCTAssertEqual(model.lastAddedCard, original.snapshot)
        XCTAssertFalse(model.canUndoLastAdd)
        try await waitForQuickActions(model)
        model.undoLastAdd(list: list, context: context)
        try await waitForIdle(model)
        XCTAssertEqual(list.quantity, 0, "A later explicit Undo can still remove the original addition")
        XCTAssertEqual(model.selected?.identity.productID, "p:101")
    }

    func testFailedCopyKeepsPriorReceiptAndStagedDataThenRetryAddsExactlyOneRow() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        var saves = 0, refuseCopy = true
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 3, skuID: "3")),
                                     quickActionCooldown: .zero, saveCard: { card, session, list, context, ref in
            saves += 1
            if saves > 1 && refuseCopy {
                try CardListService.add(card, to: list, context: context); session.record(card)
                throw InjectedActionFailure.writeRefused
            }
            try SessionService.add(card, session: session, list: list, context: context, recognitionRef: ref)
        })
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = try await confirm(card(101), model: model, list: list, context: context)
        let pending = CardList(name: "Unrelated pending list"); context.insert(pending)
        model.addAnotherCopy(list: list, context: context)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(list.orderedCards.map(\.id), [original.id])
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, 3)
        XCTAssertEqual(model.lastAddedCard, original.snapshot)
        XCTAssertTrue(model.canAddAnotherCopy)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).contains { $0.id == pending.id })
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CardList>()), 1,
                       "A failed copy must leave unrelated insertion staged")
        refuseCopy = false
        model.addAnotherCopy(list: list, context: context)
        XCTAssertNil(model.error); XCTAssertEqual(list.quantity, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 2)
        XCTAssertEqual(session.addedQuantity, 2); XCTAssertEqual(session.knownValue, 6)
    }

    func testFailedUndoKeepsTheCommittedRowAndCanBeRetried() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        var refuseUndo = true
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 4, skuID: "4")),
                                     quickActionCooldown: .zero, undoCard: { receipt, session, list, context in
            if refuseUndo {
                try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context, save: { _ in
                    throw InjectedActionFailure.writeRefused
                })
                return
            }
            try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context)
        })
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = try await confirm(card(101), model: model, list: list, context: context)
        model.undoLastAdd(list: list, context: context)
        XCTAssertNotNil(model.error); XCTAssertNil(model.selected)
        XCTAssertEqual(list.orderedCards.map(\.id), [original.id])
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, 4)
        XCTAssertEqual(model.lastAddedCard, original.snapshot)
        XCTAssertTrue(model.canUndoLastAdd)
        refuseUndo = false
        model.undoLastAdd(list: list, context: context)
        try await waitForIdle(model)
        XCTAssertNil(model.error); XCTAssertEqual(list.quantity, 0)
        XCTAssertEqual(session.addedQuantity, 0); XCTAssertEqual(session.knownValue, 0)
        XCTAssertEqual(model.selected?.identity.productID, "p:101")
    }

    func testQuickActionsCannotReplaceAPendingReviewAndWorkWhileCameraIsPaused() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 1, skuID: "1")),
                                     quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = try await confirm(card(101), model: model, list: list, context: context)
        let pending = ScanResult(id: UUID(), candidates: [card(102)], accepted: true, same: false)
        model.receive(pending); try await waitForIdle(model)
        XCTAssertFalse(model.canAddAnotherCopy); XCTAssertFalse(model.canUndoLastAdd)
        model.addAnotherCopy(list: list, context: context); model.undoLastAdd(list: list, context: context)
        XCTAssertEqual(model.result?.id, pending.id)
        XCTAssertEqual(model.selected?.identity.productID, "p:102")
        XCTAssertEqual(list.orderedCards.map(\.id), [original.id])
        model.scanNextCard(); model.paused = true
        XCTAssertTrue(model.canAddAnotherCopy)
        model.addAnotherCopy(list: list, context: context)
        XCTAssertEqual(list.quantity, 2)
        model.undoLastAdd(list: list, context: context)
        XCTAssertEqual(list.orderedCards.map(\.id), [original.id])
        XCTAssertTrue(model.paused); XCTAssertNil(model.selected)
    }

    func testEditedDeletedNewerAndCompletedTargetsDisableBothQuickActions() async throws {
        for change in 0..<4 {
            let container = try store(), context = container.mainContext
            let (session, list) = try batch(context)
            let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                         pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 1, skuID: "1")),
                                         quickActionCooldown: .zero)
            model.start(game: "Pokémon", list: list, context: context, session: session)
            defer { model.stop() }
            let saved = try await confirm(card(101), model: model, list: list, context: context)
            switch change {
            case 0:
                var edited = saved.snapshot; edited.identity.condition = "Damaged"
                try CardListService.edit(saved, card: edited, quantity: 1, cashOverride: nil,
                                         tradeOverride: nil, maximumOverride: nil, context: context)
            case 1:
                list.cards.removeAll { $0.id == saved.id }; context.delete(saved); try context.save()
            case 2:
                try SessionService.add(card(102), session: session, list: list, context: context)
            default:
                try SessionService.finish(session, context: context)
            }
            let expectedIDs = list.orderedCards.map(\.id), quantity = session.addedQuantity
            XCTAssertFalse(model.canAddAnotherCopy); XCTAssertFalse(model.canUndoLastAdd)
            model.addAnotherCopy(list: list, context: context); model.undoLastAdd(list: list, context: context)
            XCTAssertEqual(list.orderedCards.map(\.id), expectedIDs)
            XCTAssertEqual(session.addedQuantity, quantity)
            XCTAssertNil(model.selected)
        }
    }

    func testRepeatedSavedFramesCannotPersistCopiesWithoutExplicitCopyAction() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                     pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 1, skuID: "1")),
                                     quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let current = card(101), episode = UUID()
        try await confirm(current, model: model, list: list, context: context, episode: episode)
        for index in 0..<40 {
            model.receive(ScanResult(id: episode, candidates: [current], accepted: true, same: index % 2 == 0))
        }
        XCTAssertNil(model.selected); XCTAssertEqual(list.quantity, 1)
        model.addAnotherCopy(list: list, context: context)
        for _ in 0..<40 {
            model.receive(ScanResult(id: episode, candidates: [current], accepted: true, same: false))
        }
        XCTAssertNil(model.selected); XCTAssertEqual(list.quantity, 2)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1])
    }

    func testCopiedRowsRetainPhysicalOrderAndCSVAfterReopeningInventory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scanner-copy.store")
        let expected = ["p:101", "p:101", "p:102", "p:101"]
        var expectedIDs: [UUID] = []
        do {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let (session, list) = try batch(context)
            let model = ScannerViewModel(provider: QuickActionScannerProvider(),
                                         pricing: QuickActionPricing(quote: MarketQuote(marketPrice: 2, skuID: "2")),
                                         quickActionCooldown: .zero)
            model.start(game: "Pokémon", list: list, context: context, session: session)
            try await confirm(card(101), model: model, list: list, context: context)
            model.addAnotherCopy(list: list, context: context)
            try await confirm(card(102), model: model, list: list, context: context)
            try await confirm(card(101), model: model, list: list, context: context)
            expectedIDs = list.orderedCards.map(\.id)
            XCTAssertEqual(Set(expectedIDs).count, 4)
            model.stop()
        }
        let reopened = try AppPersistence.open(url: url), context = reopened.mainContext
        let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertEqual(list.orderedCards.map(\.id), expectedIDs)
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.productID }, expected)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [1, 1, 1, 1])
        let csv = CSVExportService.render(list.orderedCards.map { ExportRow(card: $0.snapshot, quantity: $0.quantity) })
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5)
        for (index, ref) in expected.enumerated() {
            XCTAssertTrue(lines[index + 1].contains(CSVExportService.escape(ref)))
        }
    }
}

@MainActor private final class QuickActionScannerProvider: ScannerProvider {
    let label = "Quick action test scanner"
    let results: AsyncStream<ScanResult> = AsyncStream { _ in }
    private(set) var starts = 0
    private(set) var stops = 0
    func start(game: String) { starts += 1 }
    func stop() { stops += 1 }
    func clearCache() async throws {}
}

private actor QuickActionPricing: MarketPricing {
    private var response: MarketQuote?
    private(set) var count = 0
    init(quote: MarketQuote?) { response = quote }
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        count += 1
        return response
    }
    func replaceQuote(_ quote: MarketQuote?) { response = quote }
}
