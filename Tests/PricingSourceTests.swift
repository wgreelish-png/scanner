import XCTest
@testable import CardShowScanner

@MainActor final class PricingSourceTests: XCTestCase {
    private func card(_ ref: String = "p:1") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, printing: "Normal"),
            name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, confidence: 95, printings: ["Normal"])
    }

    func testMissingUnknownAndCorruptSettingsRetainExistingSource() async {
        let defaults = UserDefaults.standard, key = PricingSource.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(PricingSource.current, .tcgTracking)
        let invalidValues: [Any] = ["future-provider", "", 42, ["invalid": "value"]]
        for invalid in invalidValues {
            defaults.set(invalid, forKey: key)
            XCTAssertEqual(PricingSource.current, .tcgTracking)
        }
        defaults.set(PricingSource.openAPI.rawValue, forKey: key)
        XCTAssertEqual(PricingSource.current, .openAPI)
        defaults.set(PricingSource.tcgTracking.rawValue, forKey: key)
        XCTAssertEqual(PricingSource.current, .tcgTracking)
        defaults.removeObject(forKey: key)
        XCTAssertEqual(PricingSource.current, .tcgTracking)
    }

    func testMetadataUsesProviderUpdateDateAndSurvivesCoding() async throws {
        let updated = Date(timeIntervalSince1970: 1_000), fetched = Date(timeIntervalSince1970: 2_000)
        let metadata = MarketPriceMetadata(source: .openAPI, updatedAt: updated, fetchedAt: fetched)
        XCTAssertEqual(try JSONDecoder().decode(MarketPriceMetadata.self, from: JSONEncoder().encode(metadata)), metadata)
        XCTAssertEqual(metadata.summary, "Open API • data updated " + updated.formatted(date: .abbreviated, time: .shortened))
        XCTAssertEqual(MarketPriceMetadata(source: .openAPI, fetchedAt: fetched).summary, "Open API")
        XCTAssertEqual(MarketPriceMetadata(source: .tcgTracking, fetchedAt: fetched).summary, "Existing TCGTracking")
    }

    func testPrepareAndDetailsUseOnlySelectedProviderAndForwardInputs() async throws {
        let legacy = SourcePricingSpy(price: 1), open = SourcePricingSpy(price: 2)
        let selection = PricingSourceSelection(.openAPI)
        let router = SelectedMarketPricing(legacy: legacy, openAPI: open, source: { selection.get() })
        await router.prepare()
        let selected = card(), candidates = [card("p:2"), selected]
        let details = try await router.details(for: selected, candidates: candidates, forceRefresh: true)
        XCTAssertEqual(details.quote?.marketPrice, 2)
        XCTAssertEqual(details.metadata?.source, .openAPI)
        XCTAssertNil(details.metadata?.updatedAt)
        let legacyStats = await legacy.statistics(), openStats = await open.statistics()
        XCTAssertEqual(legacyStats.preparations, 0); XCTAssertTrue(legacyStats.requests.isEmpty)
        XCTAssertEqual(openStats.preparations, 1); XCTAssertEqual(openStats.requests.count, 1)
        XCTAssertEqual(openStats.requests[0].card, selected)
        XCTAssertEqual(openStats.requests[0].candidates, candidates)
        XCTAssertTrue(openStats.requests[0].forceRefresh)
        selection.set(.tcgTracking)
        await router.prepare()
        let quote = try await router.quote(for: selected)
        XCTAssertEqual(quote?.marketPrice, 1)
        let laterLegacy = await legacy.statistics(), laterOpen = await open.statistics()
        XCTAssertEqual(laterLegacy.preparations, 1); XCTAssertEqual(laterLegacy.requests.count, 1)
        XCTAssertEqual(laterLegacy.requests[0].candidates, [selected])
        XCTAssertFalse(laterLegacy.requests[0].forceRefresh)
        XCTAssertEqual(laterOpen.requests.count, 1)
    }

    func testProviderErrorsAndMissingQuotesNeverFallBack() async throws {
        let legacy = SourcePricingSpy(price: 1), open = SourcePricingSpy(price: nil, failure: .rejected)
        let router = SelectedMarketPricing(legacy: legacy, openAPI: open, source: { .openAPI })
        do {
            _ = try await router.quote(for: card())
            XCTFail("The selected provider's error must propagate")
        } catch { XCTAssertEqual(error as? SourcePricingFailure, .rejected) }
        await open.setFailure(nil)
        let quote = try await router.quote(for: card(), candidates: [card("p:2")])
        XCTAssertNil(quote)
        let legacyStats = await legacy.statistics(), openStats = await open.statistics()
        XCTAssertTrue(legacyStats.requests.isEmpty)
        XCTAssertEqual(openStats.requests.count, 2)
        XCTAssertEqual(openStats.requests[1].candidates, [card("p:2")])
    }

    func testProviderMetadataIsPreservedAcrossCachedLookups() async throws {
        let metadata = MarketPriceMetadata(source: .openAPI, updatedAt: Date(timeIntervalSince1970: 100),
            fetchedAt: Date(timeIntervalSince1970: 200))
        let open = SourcePricingSpy(price: 2, metadata: metadata)
        let router = SelectedMarketPricing(legacy: SourcePricingSpy(price: 1), openAPI: open, source: { .openAPI })
        let first = try await router.details(for: card(), candidates: [], forceRefresh: false)
        let second = try await router.details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertEqual(first.metadata, metadata)
        XCTAssertEqual(second.metadata, metadata, "Reusing cached data must not make its provider date appear newer")
    }

    func testLegacyResponsesReceiveSourceWithoutInventingDataUpdateTime() async throws {
        let before = Date()
        let router = SelectedMarketPricing(legacy: SourcePricingSpy(price: 1), openAPI: SourcePricingSpy(price: 2), source: { .tcgTracking })
        let result = try await router.details(for: card(), candidates: [], forceRefresh: false)
        let metadata = try XCTUnwrap(result.metadata)
        XCTAssertEqual(metadata.source, .tcgTracking); XCTAssertNil(metadata.updatedAt)
        XCTAssertGreaterThanOrEqual(metadata.fetchedAt, before)
        XCTAssertLessThanOrEqual(metadata.fetchedAt, Date())
    }

    func testSwitchingSourceRejectsPendingResult() async throws {
        let pending = PendingSourcePricing(), selection = PricingSourceSelection(.openAPI)
        let router = SelectedMarketPricing(legacy: SourcePricingSpy(price: 1), openAPI: pending, source: { selection.get() })
        let selected = card()
        let task = Task { try await router.details(for: selected, candidates: [selected], forceRefresh: false) }
        try await waitForRequest(pending)
        selection.set(.tcgTracking)
        await pending.resolve()
        do { _ = try await task.value; XCTFail("A previous source cannot publish after switching") }
        catch { XCTAssertTrue(error is CancellationError) }
        let current = try await router.quote(for: selected)
        XCTAssertEqual(current?.marketPrice, 1)
    }

    func testCancellationRejectsProviderThatIgnoresCancellation() async throws {
        let pending = PendingSourcePricing()
        let router = SelectedMarketPricing(legacy: pending, openAPI: SourcePricingSpy(price: 2), source: { .tcgTracking })
        let selected = card()
        let task = Task { try await router.quote(for: selected) }
        try await waitForRequest(pending)
        task.cancel()
        await pending.resolve()
        do { _ = try await task.value; XCTFail("Cancelled lookups must not publish a quote") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSwitchingPreservesIndependentProviderCachesAndRefreshFlags() async throws {
        let legacy = SourcePricingSpy(price: 1), open = SourcePricingSpy(price: 2)
        let selection = PricingSourceSelection(.tcgTracking)
        let router = SelectedMarketPricing(legacy: legacy, openAPI: open, source: { selection.get() })
        let selected = card()
        for source in [PricingSource.tcgTracking, .openAPI, .tcgTracking, .openAPI] {
            selection.set(source)
            let result = try await router.details(for: selected, candidates: [selected], forceRefresh: false)
            XCTAssertEqual(result.quote?.marketPrice, source == .tcgTracking ? 1 : 2)
        }
        let cachedLegacy = await legacy.statistics(), cachedOpen = await open.statistics()
        XCTAssertEqual(cachedLegacy.loads, 1); XCTAssertEqual(cachedOpen.loads, 1)
        _ = try await router.details(for: selected, candidates: [selected], forceRefresh: true)
        let refreshedLegacy = await legacy.statistics(), refreshedOpen = await open.statistics()
        XCTAssertEqual(refreshedLegacy.loads, 1); XCTAssertEqual(refreshedOpen.loads, 2)
        XCTAssertEqual(refreshedLegacy.requests.map(\.forceRefresh), [false, false])
        XCTAssertEqual(refreshedOpen.requests.map(\.forceRefresh), [false, false, true])
    }

    private func waitForRequest(_ provider: PendingSourcePricing) async throws {
        for _ in 0..<100 {
            let started = await provider.started
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The pricing request did not start")
        throw SourcePricingFailure.rejected
    }
}

private final class PricingSourceSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PricingSource
    init(_ value: PricingSource) { self.value = value }
    func get() -> PricingSource { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: PricingSource) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private enum SourcePricingFailure: Error, Equatable { case rejected }
private struct SourcePricingRequest: Sendable {
    var card: CardCandidate
    var candidates: [CardCandidate]
    var forceRefresh: Bool
}
private struct SourcePricingStatistics: Sendable {
    var preparations: Int
    var requests: [SourcePricingRequest]
    var loads: Int
}
private actor SourcePricingSpy: MarketPricing {
    private var preparations = 0
    private var requests: [SourcePricingRequest] = []
    private var loads = 0
    private let price: Decimal?
    private let metadata: MarketPriceMetadata?
    private var failure: SourcePricingFailure?
    private var cached = false
    init(price: Decimal?, metadata: MarketPriceMetadata? = nil, failure: SourcePricingFailure? = nil) {
        self.price = price; self.metadata = metadata; self.failure = failure
    }
    func prepare() async { preparations += 1 }
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        requests.append(SourcePricingRequest(card: card, candidates: candidates, forceRefresh: forceRefresh))
        if let failure { throw failure }
        if forceRefresh || !cached { loads += 1; cached = true }
        return MarketDetails(quote: price.map { MarketQuote(marketPrice: $0, skuID: nil) }, metadata: metadata)
    }
    func setFailure(_ failure: SourcePricingFailure?) { self.failure = failure }
    func statistics() -> SourcePricingStatistics {
        SourcePricingStatistics(preparations: preparations, requests: requests, loads: loads)
    }
}
private actor PendingSourcePricing: MarketPricing {
    private var continuation: CheckedContinuation<MarketDetails, Never>?
    private(set) var started = false
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
    }
    func resolve() {
        continuation?.resume(returning: MarketDetails(quote: MarketQuote(marketPrice: 99, skuID: nil)))
        continuation = nil
    }
}
