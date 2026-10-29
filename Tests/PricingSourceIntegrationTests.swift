import XCTest
import SwiftData
@testable import CardShowScanner

/// Exercises source changes at the review, editor, and saved-inventory boundaries.
@MainActor final class PricingSourceIntegrationTests: XCTestCase {
    private let legacyMetadata = MarketPriceMetadata(source: .tcgTracking, fetchedAt: Date(timeIntervalSince1970: 100))
    private let publicMetadata = MarketPriceMetadata(source: .openAPI, updatedAt: Date(timeIntervalSince1970: 200),
                                                     fetchedAt: Date(timeIntervalSince1970: 300))

    private func card(_ product: String = "p:101") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: product, printing: "Normal"),
                      name: "Source fixture", set: "Fixture set", number: "1/100", marketPrice: 10,
                      confidence: 96, printings: ["Normal", "Holofoil"])
    }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func batch(_ context: ModelContext) throws -> (ScanSession, CardList) {
        let session = try SessionService.start(game: "Pokémon", context: context)
        return (session, try XCTUnwrap(SessionService.list(for: session, context: context)))
    }

    func testScannerSourceChangeKeepsFrozenReviewAndUserSelectionsWhileRejectingOldReply() async throws {
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing)
        let candidates = [card(), card("p:102")]
        let frozen = ScanResult(id: UUID(), candidates: candidates, accepted: true, same: false,
                                capturedImageData: Data([7, 8, 9]))
        model.receive(frozen)
        try await waitForRequests(1, pricing)
        await pricing.resolve(0, price: 10, sku: "legacy-nm", metadata: legacyMetadata,
                              printingsByProduct: ["p:102": ["Old source finish"]])
        try await waitUntil { !model.priceLoading }
        model.changeCondition("Lightly Played")
        try await waitForRequests(2, pricing)
        await pricing.resolve(1, price: 8, sku: "legacy-lp", metadata: legacyMetadata,
                              printingsByProduct: ["p:102": ["Old source finish"]])
        try await waitUntil { !model.priceLoading }
        model.changePrinting("Holofoil")
        try await waitForRequests(3, pricing)

        model.pricingSourceChanged()

        XCTAssertEqual(model.result?.id, frozen.id)
        XCTAssertEqual(model.result?.candidates, frozen.candidates)
        XCTAssertEqual(model.result?.capturedImageData, frozen.capturedImageData)
        XCTAssertEqual(model.selected?.identity.productID, "p:101")
        XCTAssertEqual(model.selected?.identity.condition, "Lightly Played")
        XCTAssertEqual(model.selected?.identity.printing, "Holofoil")
        XCTAssertNil(model.selected?.marketPrice)
        XCTAssertNil(model.selected?.marketPriceMetadata)
        XCTAssertFalse(model.printings(for: candidates[1]).contains("Old source finish"))
        try await waitForRequests(4, pricing)
        let request = await pricing.requests[3]
        XCTAssertTrue(request.forceRefresh)
        XCTAssertEqual(request.candidates, frozen.candidates)
        await pricing.resolve(3, price: 3, sku: "public-lp-holo", metadata: publicMetadata,
                              printingsByProduct: ["p:101": ["Normal", "Holofoil"], "p:102": ["Normal", "Holofoil"]])
        try await waitUntil { !model.priceLoading }
        await pricing.resolve(2, price: 99, sku: "stale-legacy", metadata: legacyMetadata)
        await settle()

        XCTAssertEqual(model.selected?.marketPrice, 3)
        XCTAssertEqual(model.selected?.identity.skuID, "public-lp-holo")
        XCTAssertEqual(model.selected?.marketPriceMetadata, publicMetadata)
        XCTAssertEqual(model.result?.id, frozen.id)
    }

    func testSourceChangeCancelsQueuedConfirmationAndItsDeadlineUntilAnotherExplicitTap() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing,
                                     confirmationTimeout: .seconds(1), quickActionCooldown: .zero)
        model.start(game: "Pokémon", list: list, context: context, session: session)
        defer { model.stop() }
        let original = card()
        model.receive(ScanResult(id: UUID(), candidates: [original], accepted: true, same: false))
        try await waitForRequests(1, pricing)
        model.selectAndAdd(original, list: list, context: context)
        try await waitForRequests(2, pricing)
        XCTAssertTrue(model.selectionInProgress)

        model.pricingSourceChanged()
        XCTAssertFalse(model.selectionInProgress)
        try await waitForRequests(3, pricing)
        await pricing.resolve(2, price: 4, sku: "public", metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        await pricing.resolve(1, price: 90, sku: "old-confirmation", metadata: legacyMetadata)
        await pricing.resolve(0, price: 80, sku: "old-review", metadata: legacyMetadata)
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(list.quantity, 0, "Changing a source must retire the earlier Add tap and its timeout")
        XCTAssertEqual(session.addedQuantity, 0)
        XCTAssertNotNil(model.selected)

        model.selectAndAdd(original, list: list, context: context)
        XCTAssertEqual(list.quantity, 1)
        XCTAssertEqual(list.orderedCards.first?.snapshot.marketPrice, 4)
        XCTAssertEqual(list.orderedCards.first?.snapshot.marketPriceMetadata, publicMetadata)
    }

    func testEditorSourceChangeUpdatesDraftOnlyAndLateReplyCannotAlterSavedInventory() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Saved inventory"); context.insert(list)
        var saved = card(); saved.identity.skuID = "saved-sku"; saved.marketPriceMetadata = legacyMetadata
        try CardListService.add(saved, to: list, context: context); try context.save()
        let item = try XCTUnwrap(list.orderedCards.first), originalData = item.data
        let pricing = SourceIntegrationPricing()
        let model = CardEditorPricingModel(card: item.snapshot, pricing: pricing)
        model.changeIdentity { $0.condition = "Moderately Played" }
        try await waitForRequests(1, pricing)
        model.pricingSourceChanged()
        try await waitForRequests(2, pricing)
        await pricing.resolve(1, price: 2, sku: "public-edited", metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        await pricing.resolve(0, price: 9, sku: "stale-edited", metadata: legacyMetadata)
        await settle()

        XCTAssertEqual(model.card.identity.condition, "Moderately Played")
        XCTAssertEqual(model.card.marketPrice, 2)
        XCTAssertEqual(model.card.marketPriceMetadata, publicMetadata)
        XCTAssertEqual(item.snapshot, saved)
        XCTAssertEqual(item.data, originalData)
        let reopenedRow = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<InventoryCard>()).first)
        XCTAssertEqual(reopenedRow.snapshot, saved, "A source selection cannot implicitly save an inventory edit")
    }

    func testSourceChangeRejectsOldAlternatePrintingPrefetchWithoutReplacingSelectedQuote() async throws {
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing)
        let candidates = [card(), card("p:102")]
        let frozen = ScanResult(id: UUID(), candidates: candidates, accepted: true, same: false)
        model.receive(frozen)
        try await waitForRequests(1, pricing)
        await pricing.resolve(0, price: 5, sku: "public", metadata: publicMetadata)
        try await waitForRequests(2, pricing)
        let prefetched = await pricing.requests[1]
        XCTAssertEqual(prefetched.card.identity.productID, "p:102")
        XCTAssertFalse(model.priceLoading, "Other match menus must not delay the selected card's quote")
        XCTAssertEqual(model.selected?.marketPrice, 5)

        model.pricingSourceChanged()
        try await waitForRequests(3, pricing)
        await pricing.resolve(2, price: 7, sku: "new-source", metadata: legacyMetadata,
                              printingsByProduct: ["p:102": ["New source finish"]])
        try await waitUntil { !model.priceLoading }
        await pricing.resolve(1, price: 99, sku: "old-alternate", metadata: publicMetadata)
        await settle()

        XCTAssertEqual(model.selected?.marketPrice, 7)
        XCTAssertEqual(model.selected?.identity.skuID, "new-source")
        XCTAssertEqual(model.selected?.marketPriceMetadata, legacyMetadata)
        XCTAssertEqual(model.printings(for: candidates[1]), ["New source finish", "Normal"])
        XCTAssertEqual(model.result?.id, frozen.id)
    }

    func testOldInventoryJSONWithoutProvenanceStillDecodesWithItsSavedQuote() async throws {
        let oldJSON = Data(#"{"identity":{"game":"Pokémon","productID":"p:101","skuID":"original","printing":"Normal","language":"English","condition":"Near Mint"},"name":"Original card","set":"Original set","number":"1/100","marketPrice":10.25,"confidence":96,"printings":["Normal"]}"#.utf8)
        let decoded = try JSONDecoder().decode(CardCandidate.self, from: oldJSON)
        XCTAssertEqual(decoded.identity.skuID, "original")
        XCTAssertEqual(decoded.marketPrice, Decimal(string: "10.25"))
        XCTAssertNil(decoded.marketPriceMetadata)
        let row = try InventoryCard(card: decoded)
        row.data = oldJSON
        XCTAssertEqual(row.snapshot, decoded, "Existing disk rows must not become unreadable when metadata is added")
    }

    func testProvenanceSurvivesConfirmedCopyAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pricing-provenance.store")
        var savedIDs: [UUID] = []
        do {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let (session, list) = try batch(context)
            let pricing = SourceIntegrationPricing()
            let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing, quickActionCooldown: .zero)
            model.start(game: "Pokémon", list: list, context: context, session: session)
            defer { model.stop() }
            let original = card()
            model.receive(ScanResult(id: UUID(), candidates: [original], accepted: true, same: false))
            try await waitForRequests(1, pricing)
            await pricing.resolve(0, price: 0, sku: "known-zero", metadata: publicMetadata)
            try await waitUntil { !model.priceLoading }
            model.selectAndAdd(original, list: list, context: context)
            XCTAssertEqual(model.lastAddedCard?.marketPriceMetadata, publicMetadata)
            model.addAnotherCopy(list: list, context: context)
            savedIDs = list.orderedCards.map(\.id)
            XCTAssertEqual(list.quantity, 2)
            XCTAssertEqual(list.orderedCards.map { $0.snapshot.marketPriceMetadata }, [publicMetadata, publicMetadata])
        }
        let reopened = try AppPersistence.open(url: url), context = reopened.mainContext
        let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first)
        XCTAssertEqual(list.orderedCards.map(\.id), savedIDs)
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.marketPrice }, [Decimal.zero, Decimal.zero])
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.marketPriceMetadata }, [publicMetadata, publicMetadata])
        XCTAssertEqual(list.unpricedQuantity, 0)
    }

    func testScannerKnownZeroKeepsProvenanceButMissingQuoteAndRetryClearIt() async throws {
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing)
        let original = card()
        model.receive(ScanResult(id: UUID(), candidates: [original], accepted: true, same: false))
        try await waitForRequests(1, pricing)
        await pricing.resolve(0, price: 0, sku: "zero", metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        XCTAssertEqual(model.selected?.marketPrice, 0)
        XCTAssertEqual(model.selected?.marketPriceMetadata, publicMetadata)

        model.refreshPrice()
        XCTAssertNil(model.selected?.marketPriceMetadata)
        try await waitForRequests(2, pricing)
        await pricing.resolve(1, price: nil, sku: "unpriced-sku", metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        XCTAssertNil(model.selected?.marketPrice)
        XCTAssertEqual(model.selected?.identity.skuID, "unpriced-sku")
        XCTAssertNil(model.selected?.marketPriceMetadata)
        XCTAssertNotNil(model.priceMessage)
    }

    func testEditorKnownZeroKeepsProvenanceButUnavailableQuoteDoesNot() async throws {
        let pricing = SourceIntegrationPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.pricingSourceChanged()
        try await waitForRequests(1, pricing)
        await pricing.resolve(0, price: 0, sku: "zero", metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        XCTAssertEqual(model.card.marketPrice, 0)
        XCTAssertEqual(model.card.marketPriceMetadata, publicMetadata)
        XCTAssertEqual(model.price, "0")
        model.refreshPrice()
        XCTAssertNil(model.card.marketPriceMetadata)
        try await waitForRequests(2, pricing)
        await pricing.resolve(1, price: nil, sku: nil, metadata: publicMetadata)
        try await waitUntil { !model.priceLoading }
        XCTAssertNil(model.card.marketPrice)
        XCTAssertNil(model.card.marketPriceMetadata)
        XCTAssertEqual(model.price, "")
    }

    func testManualPriceAndSKUChangesRemoveProviderProvenance() async {
        var saved = card(); saved.marketPriceMetadata = publicMetadata; saved.identity.skuID = "provider-sku"
        let priceEdit = CardEditorPricingModel(card: saved, pricing: SourceIntegrationPricing())
        priceEdit.setPrice("12.50")
        XCTAssertEqual(priceEdit.card.marketPrice, Decimal(string: "12.50"))
        XCTAssertEqual(priceEdit.card.identity.skuID, "provider-sku")
        XCTAssertNil(priceEdit.card.marketPriceMetadata)
        let skuEdit = CardEditorPricingModel(card: saved, pricing: SourceIntegrationPricing())
        skuEdit.setSKU("manual-sku")
        XCTAssertEqual(skuEdit.card.identity.skuID, "manual-sku")
        XCTAssertNil(skuEdit.card.marketPriceMetadata)
        XCTAssertEqual(saved.marketPriceMetadata, publicMetadata)
    }

    func testManualAddDraftClearsInheritedQuoteAndProvenanceBeforeAnyLookup() async {
        var saved = card(); saved.marketPriceMetadata = publicMetadata; saved.identity.skuID = "saved-sku"
        let model = ManualCardAddModel(card: saved, pricing: SourceIntegrationPricing())
        XCTAssertNil(model.pricing.card.marketPrice)
        XCTAssertNil(model.pricing.card.identity.skuID)
        XCTAssertNil(model.pricing.card.marketPriceMetadata)
        XCTAssertEqual(saved.marketPriceMetadata, publicMetadata)
    }

    func testScannerPublic403DoesNotAskForWebsiteConnectionWhileLegacy403Does() async throws {
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing)
        model.receive(ScanResult(id: UUID(), candidates: [card()], accepted: true, same: false))
        try await waitForRequests(1, pricing)
        await pricing.reject(0, error: MarketPricingFailure.accessRejected(403))
        try await waitUntil { !model.priceLoading }
        XCTAssertTrue(model.priceConnectionRequired)
        model.pricingSourceChanged()
        try await waitForRequests(2, pricing)
        await pricing.reject(1, error: OpenAPIPricingFailure.httpStatus(403))
        try await waitUntil { !model.priceLoading }
        XCTAssertFalse(model.priceConnectionRequired)
        XCTAssertTrue(model.priceMessage?.contains("403") == true)
        XCTAssertFalse(model.priceMessage?.contains("Connect TCGTracking") == true)
        XCTAssertNotNil(model.selected)
    }

    func testEditorPublic403DoesNotAskForWebsiteConnectionWhileLegacy403Does() async throws {
        let pricing = SourceIntegrationPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.refreshPrice()
        try await waitForRequests(1, pricing)
        await pricing.reject(0, error: MarketPricingFailure.accessRejected(403))
        try await waitUntil { !model.priceLoading }
        XCTAssertTrue(model.priceConnectionRequired)
        model.pricingSourceChanged()
        try await waitForRequests(2, pricing)
        await pricing.reject(1, error: OpenAPIPricingFailure.httpStatus(403))
        try await waitUntil { !model.priceLoading }
        XCTAssertFalse(model.priceConnectionRequired)
        XCTAssertTrue(model.priceMessage?.contains("403") == true)
        XCTAssertFalse(model.priceMessage?.contains("Connect TCGTracking") == true)
    }

    func testLeavingReviewForConnectionClearsQuoteProvenance() async throws {
        let pricing = SourceIntegrationPricing()
        let model = ScannerViewModel(provider: SourceIntegrationScanner(), pricing: pricing)
        let frozen = ScanResult(id: UUID(), candidates: [card()], accepted: true, same: false)
        model.receive(frozen)
        try await waitForRequests(1, pricing)
        await pricing.resolve(0, price: 6, sku: "legacy", metadata: legacyMetadata)
        try await waitUntil { !model.priceLoading }
        XCTAssertNotNil(model.selected?.marketPriceMetadata)
        XCTAssertTrue(model.suspendForPricingConnection())
        XCTAssertNil(model.selected?.marketPrice)
        XCTAssertNil(model.selected?.identity.skuID)
        XCTAssertNil(model.selected?.marketPriceMetadata)
        XCTAssertEqual(model.result?.id, frozen.id)
    }

    private func waitForRequests(_ count: Int, _ pricing: SourceIntegrationPricing) async throws {
        for _ in 0..<200 {
            let received = await pricing.requests.count
            if received >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected pricing request \(count) did not start")
        throw URLError(.timedOut)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The pricing result did not settle")
        throw URLError(.timedOut)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

private actor SourceIntegrationPricing: MarketPricing {
    struct Request: Sendable {
        let card: CardCandidate
        let candidates: [CardCandidate]
        let forceRefresh: Bool
    }
    private(set) var requests: [Request] = []
    private var pending: [CheckedContinuation<MarketDetails, Error>?] = []

    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }

    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        requests.append(Request(card: card, candidates: candidates, forceRefresh: forceRefresh))
        // Deliberately finish after cancellation to exercise each model's stale-reply protection.
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func resolve(_ index: Int, price: Decimal?, sku: String?, metadata: MarketPriceMetadata?,
                 printingsByProduct: [String: [String]] = [:]) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume(returning: MarketDetails(quote: MarketQuote(marketPrice: price, skuID: sku),
            printings: ["Normal", "Holofoil"], printingsByProduct: printingsByProduct, metadata: metadata))
    }

    func reject(_ index: Int, error: Error) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume(throwing: error)
    }
}

@MainActor private final class SourceIntegrationScanner: ScannerProvider {
    let label = "Source integration scanner"
    let results: AsyncStream<ScanResult> = AsyncStream { _ in }
    func start(game: String) {}
    func stop() {}
    func clearCache() async throws {}
}
