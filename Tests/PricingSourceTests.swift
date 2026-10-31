import XCTest
@testable import CardShowScanner

@MainActor final class PricingSourceTests: XCTestCase {
    private func card(_ ref: String = "p:1") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: ref, printing: "Normal"),
            name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, confidence: 95, printings: ["Normal"])
    }

    func testMissingLegacyUnknownAndCorruptPreferencesAlwaysUseOpenAPI() async {
        let defaults = UserDefaults.standard, key = PricingSource.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(PricingSource.current, .openAPI)
        let oldValues: [Any] = ["tcgtracking", "openapi", "future-provider", "", 42, ["invalid": "value"]]
        for value in oldValues {
            defaults.set(value, forKey: key)
            XCTAssertEqual(PricingSource.current, .openAPI)
        }
    }

    func testHistoricalMetadataRemainsDecodableWithOriginalSourceAndDates() async throws {
        let updated = Date(timeIntervalSince1970: 1_000), fetched = Date(timeIntervalSince1970: 2_000)
        for source in [PricingSource.tcgTracking, .openAPI] {
            let metadata = MarketPriceMetadata(source: source, updatedAt: updated, fetchedAt: fetched, isCached: true)
            let encoded = try JSONEncoder().encode(metadata)
            XCTAssertEqual(try JSONDecoder().decode(MarketPriceMetadata.self, from: encoded), metadata)
        }
        let metadata = MarketPriceMetadata(source: .openAPI, updatedAt: updated, fetchedAt: fetched)
        XCTAssertEqual(metadata.summary, "Open API • data updated " + updated.formatted(date: .abbreviated, time: .shortened))
        XCTAssertEqual(MarketPriceMetadata(source: .tcgTracking, fetchedAt: fetched).summary, "Existing TCGTracking")
    }

    func testStandardProviderForwardsPreparationIdentityCandidatesAndRefreshFlag() async throws {
        let api = SourcePricingSpy(price: 2)
        let standard = StandardMarketPricing(provider: api)
        await standard.prepare()
        let selected = card(), candidates = [card("p:2"), selected]
        let details = try await standard.details(for: selected, candidates: candidates, forceRefresh: true)
        XCTAssertEqual(details.quote?.marketPrice, 2)
        XCTAssertEqual(details.metadata?.source, .openAPI)
        XCTAssertNil(details.metadata?.updatedAt)
        _ = try await standard.quote(for: selected)
        let stats = await api.statistics()
        XCTAssertEqual(stats.preparations, 1); XCTAssertEqual(stats.requests.count, 2)
        XCTAssertEqual(stats.requests[0].card, selected); XCTAssertEqual(stats.requests[0].candidates, candidates)
        XCTAssertTrue(stats.requests[0].forceRefresh)
        XCTAssertEqual(stats.requests[1].candidates, [selected]); XCTAssertFalse(stats.requests[1].forceRefresh)
    }

    func testErrorsAndMissingQuotesNeverTriggerAnAlternateProviderOrRetry() async throws {
        let api = SourcePricingSpy(price: nil, failure: .rejected)
        let standard = StandardMarketPricing(provider: api)
        do {
            _ = try await standard.quote(for: card())
            XCTFail("A public pricing failure must remain a failure")
        } catch { XCTAssertEqual(error as? SourcePricingFailure, .rejected) }
        let afterFailure = await api.statistics()
        XCTAssertEqual(afterFailure.requests.count, 1, "A failed lookup must not retry automatically")
        await api.setFailure(nil)
        let quote = try await standard.quote(for: card(), candidates: [card("p:2")])
        XCTAssertNil(quote)
        let afterMissing = await api.statistics()
        XCTAssertEqual(afterMissing.requests.count, 2)
        XCTAssertEqual(afterMissing.requests[1].candidates, [card("p:2")])
    }

    func testKnownZeroIsPreservedAsAKnownQuote() async throws {
        let api = SourcePricingSpy(price: 0)
        let result = try await StandardMarketPricing(provider: api).details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertEqual(result.quote?.marketPrice, 0)
        XCTAssertEqual(result.metadata?.source, .openAPI)
    }

    func testCachedProviderMetadataIsNeverMadeNewerByTheWrapper() async throws {
        let metadata = MarketPriceMetadata(source: .openAPI, updatedAt: Date(timeIntervalSince1970: 100),
            fetchedAt: Date(timeIntervalSince1970: 200), isOffline: true, isCached: true)
        let standard = StandardMarketPricing(provider: SourcePricingSpy(price: 2, metadata: metadata))
        let first = try await standard.details(for: card(), candidates: [], forceRefresh: false)
        let second = try await standard.details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertEqual(first.metadata, metadata); XCTAssertEqual(second.metadata, metadata)
    }

    func testLegacyPreferenceChangesCannotRedirectAnInFlightPublicQuote() async throws {
        let defaults = UserDefaults.standard
        let key = PricingSource.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set("tcgtracking", forKey: key)
        let pending = PendingSourcePricing()
        let service = StandardMarketPricing(provider: pending), selected = card()
        let task = Task { try await service.details(for: selected, candidates: [selected], forceRefresh: false) }
        try await waitForRequest(pending)
        defaults.set("future-provider", forKey: key)
        await pending.resolve()
        let result = try await task.value
        XCTAssertEqual(result.quote?.marketPrice, 99); XCTAssertEqual(result.metadata?.source, .openAPI)
        XCTAssertEqual(PricingSource.current, .openAPI)
    }

    func testCancellationRejectsAProviderThatIgnoresCancellation() async throws {
        let pending = PendingSourcePricing()
        let standard = StandardMarketPricing(provider: pending), selected = card()
        let task = Task { try await standard.quote(for: selected) }
        try await waitForRequest(pending)
        task.cancel(); await pending.resolve()
        do { _ = try await task.value; XCTFail("Cancelled lookups must not publish a quote") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRepeatLookupsReuseTheSameProviderAndOnlyExplicitRefreshReloads() async throws {
        let api = SourcePricingSpy(price: 2), selected = card()
        let standard = StandardMarketPricing(provider: api)
        for _ in 0..<4 { _ = try await standard.details(for: selected, candidates: [selected], forceRefresh: false) }
        let cached = await api.statistics()
        XCTAssertEqual(cached.loads, 1)
        _ = try await standard.details(for: selected, candidates: [selected], forceRefresh: true)
        let refreshed = await api.statistics()
        XCTAssertEqual(refreshed.loads, 2)
        XCTAssertEqual(refreshed.requests.map(\.forceRefresh), [false, false, false, false, true])
    }

    private func waitForRequest(_ provider: PendingSourcePricing) async throws {
        for _ in 0..<100 {
            let started = await provider.started
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The pricing request did not start"); throw SourcePricingFailure.rejected
    }
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
