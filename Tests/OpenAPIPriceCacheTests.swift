import XCTest
@testable import CardShowScanner

@MainActor final class OpenAPIPriceCacheTests: XCTestCase {
    func testDailyPriceCacheReopensWithoutNetworkAndManualRefreshRevalidates() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let firstLoader = OfflineCacheLoader([.response(200, body(), "\"daily\"")])
        let first = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: firstLoader,
            now: { fetched }, cacheDirectory: folder)
        let original = try await first.details(for: card(), candidates: [], forceRefresh: false)
        let loader = OfflineCacheLoader([.response(304, Data(), "\"daily\"")])
        let later = fetched.addingTimeInterval(12 * 60 * 60)
        let restarted = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: loader,
            now: { later }, cacheDirectory: folder)
        let cached = try await restarted.details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertEqual(cached.quote, original.quote)
        XCTAssertEqual(cached.metadata?.fetchedAt, original.metadata?.fetchedAt)
        XCTAssertEqual(cached.metadata?.updatedAt, original.metadata?.updatedAt)
        XCTAssertEqual(cached.metadata?.isCached, true)
        XCTAssertNotEqual(cached.metadata?.isOffline, true)
        XCTAssertTrue(cached.metadata?.summary.contains("cached") == true)
        let played = try await restarted.details(for: card(condition: "Lightly Played"), candidates: [], forceRefresh: false)
        XCTAssertEqual(played.quote?.marketPrice, 8)
        var requests = await loader.requests
        XCTAssertEqual(requests.count, 0, "Relaunching or changing condition within one day reuses the set body")
        let refreshed = try await restarted.details(for: card(), candidates: [], forceRefresh: true)
        XCTAssertEqual(refreshed.quote, original.quote)
        XCTAssertEqual(refreshed.metadata?.updatedAt, original.metadata?.updatedAt)
        XCTAssertEqual(refreshed.metadata?.fetchedAt, later)
        requests = await loader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"daily\"")
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenAPIPriceCacheTests-" + UUID().uuidString, isDirectory: true)
    }
    private func card(condition: String = "Near Mint", printing: String = "Normal", language: String = "English") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:15038", printing: printing, language: language, condition: condition),
                      name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, confidence: 95, printings: [printing])
    }
    private func body(set: Int = 1, rows: String? = nil) -> Data {
        let rows = rows ?? #""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":0,"low":0,"hi":"1.25","cnt":0},"4640":{"cnd":"LP","var":"Normal","lng":"EN","mkt":8},"4641":{"cnd":"NM","var":"Foil","lng":"EN","mkt":9},"4642":{"cnd":"NM","var":"Normal","lng":"JP","mkt":10}"#
        return Data("{\"set_id\":\(set),\"updated\":\"2026-01-29T16:50:40Z\",\"products\":{\"15038\":{\(rows)}}}".utf8)
    }
    private func url(_ set: Int = 1) -> URL { URL(string: "https://openapi.tcgtracking.com/v1/3/sets/\(set)/skus")! }

    func testPersistentOfflineReusePreservesExactSKUContextAndOriginalDates() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), "\"daily\"")]),
                                        now: { fetched }, cacheDirectory: folder)
        let original = try await fresh.details(for: card(), candidates: [], forceRefresh: false)
        let offlineLoader = OfflineCacheLoader([.failure(URLError(.notConnectedToInternet))])
        let later = fetched.addingTimeInterval(2 * 24 * 60 * 60)
        let restarted = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: offlineLoader, now: { later }, cacheDirectory: folder)
        let cached = try await restarted.details(for: card(), candidates: [], forceRefresh: true)
        XCTAssertEqual(cached.quote, MarketQuote(marketPrice: 0, skuID: "4639"))
        XCTAssertEqual(cached.context, MarketPriceContext(lowPrice: 0, highPrice: Decimal(string: "1.25"), listingCount: 0))
        XCTAssertEqual(cached.quote, original.quote)
        XCTAssertEqual(cached.metadata?.updatedAt, original.metadata?.updatedAt)
        XCTAssertEqual(cached.metadata?.fetchedAt, fetched)
        XCTAssertEqual(cached.metadata?.isOffline, true)
        XCTAssertTrue(cached.metadata?.summary.lowercased().contains("cached") == true)
        XCTAssertTrue(cached.metadata?.summary.lowercased().contains("offline") == true)
        let requests = await offlineLoader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "If-None-Match"), "\"daily\"")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }

    func testOrdinaryLookupRetriesAfterOfflineFallbackAndClearsOfflineState() async throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let changed = body(rows: #""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":"2.50","low":"2.25","hi":3,"cnt":7}"#)
        let loader = OfflineCacheLoader([
            .response(200, body(), nil), .failure(URLError(.notConnectedToInternet)), .response(200, changed, nil)
        ])
        let pricing = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: loader, now: { fetched }, cacheDirectory: nil)
        let original = try await pricing.details(for: card(), candidates: [], forceRefresh: false)
        let fallback = try await pricing.details(for: card(), candidates: [], forceRefresh: true)
        XCTAssertEqual(fallback.quote, original.quote)
        XCTAssertEqual(fallback.metadata?.fetchedAt, original.metadata?.fetchedAt)
        XCTAssertEqual(fallback.metadata?.isOffline, true)
        let recovered = try await pricing.details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertEqual(recovered.quote, MarketQuote(marketPrice: Decimal(string: "2.50"), skuID: "4639"))
        XCTAssertEqual(recovered.context, MarketPriceContext(lowPrice: Decimal(string: "2.25"), highPrice: 3, listingCount: 7))
        XCTAssertNotEqual(recovered.metadata?.isOffline, true)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 3, "An offline result must retry online even while its original fresh interval remains open")
    }

    func testOfflineReuseNeverSubstitutesConditionPrintingLanguageOrAmbiguousSKU() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), nil)]), now: { fetched }, cacheDirectory: folder)
        _ = try await seed.quote(for: card())
        let loader = OfflineCacheLoader(Array(repeating: .failure(URLError(.networkConnectionLost)), count: 3))
        let offline = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: loader, now: { fetched.addingTimeInterval(901) }, cacheDirectory: folder)
        for selected in [card(condition: "Damaged"), card(printing: "Holofoil"), card(language: "German")] {
            let details = try await offline.details(for: selected, candidates: [], forceRefresh: true)
            XCTAssertNil(details.quote)
            XCTAssertNil(details.context)
        }
        let ambiguousFolder = directory(); defer { try? FileManager.default.removeItem(at: ambiguousFolder) }
        let ambiguousBody = body(rows: #""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":1},"9999":{"cnd":"NM","var":"Normal","lng":"EN","mkt":1}"#)
        let ambiguousSeed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, ambiguousBody, nil)]), now: { fetched }, cacheDirectory: ambiguousFolder)
        let initial = try await ambiguousSeed.details(for: card(), candidates: [], forceRefresh: false)
        XCTAssertNil(initial.quote)
        let ambiguousOffline = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.failure(URLError(.notConnectedToInternet))]), now: { fetched.addingTimeInterval(901) }, cacheDirectory: ambiguousFolder)
        let restored = try await ambiguousOffline.details(for: card(), candidates: [], forceRefresh: true)
        XCTAssertNil(restored.quote); XCTAssertNil(restored.context)
    }

    func testHTTPMalformedAndNonConnectivityFailuresDoNotUseSavedPrices() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), nil)]), now: { fetched }, cacheDirectory: folder)
        _ = try await seed.quote(for: card())
        let failures: [OfflineCacheLoader.Result] = [
            .response(401, Data(), nil), .response(403, Data(), nil), .response(404, Data(), nil), .response(503, Data(), nil),
            .response(200, Data("{}".utf8), nil), .response(200, body(set: 2), nil),
            .failure(URLError(.badServerResponse)), .failure(URLError(.cannotParseResponse)),
            .failure(URLError(.userAuthenticationRequired)), .failure(URLError(.cancelled)),
            .failure(NSError(domain: "UnrelatedErrorDomain", code: URLError.notConnectedToInternet.rawValue)),
            .failure(CancellationError())
        ]
        for failure in failures {
            let pricing = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([failure]),
                                               now: { fetched.addingTimeInterval(901) }, cacheDirectory: folder)
            do { _ = try await pricing.details(for: card(), candidates: [], forceRefresh: true); XCTFail("Only a connectivity failure can return a saved body") }
            catch { /* The response/error must remain visible to the caller. */ }
        }
    }

    func testDisabledPersistenceDoesNotReuseAnotherPricingInstance() async throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), nil)]), now: { fetched }, cacheDirectory: nil)
        _ = try await seed.quote(for: card())
        let separate = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.failure(URLError(.notConnectedToInternet))]), now: { fetched }, cacheDirectory: nil)
        do { _ = try await separate.quote(for: card()); XCTFail("An instance without a saved body cannot provide an offline quote") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testCancellationBeforeConnectivityFailureCannotPublishOfflinePrice() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), nil)]), now: { fetched }, cacheDirectory: folder)
        _ = try await seed.quote(for: card())
        let loader = OfflineCachePendingLoader()
        let pricing = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: loader, now: { fetched.addingTimeInterval(901) }, cacheDirectory: folder)
        let selected = card()
        let pending = Task { try await pricing.details(for: selected, candidates: [], forceRefresh: true) }
        try await loader.waitUntilStarted()
        pending.cancel()
        await loader.fail()
        do { _ = try await pending.value; XCTFail("A cancelled lookup cannot publish an offline price") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDiskCacheBoundRejectsFutureDatesOversizedAndNonPublicEntries() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = OpenAPIPriceDiskCache(directory: folder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for set in 1...5 {
            let date = now.addingTimeInterval(TimeInterval(set))
            cache.store(.init(data: body(set: set), etag: nil, fetchedAt: date, validatedAt: date), for: url(set), now: date)
        }
        let oldest = cache.entry(for: url(1), now: now.addingTimeInterval(10))
        let newest = cache.entry(for: url(5), now: now.addingTimeInterval(10))
        XCTAssertNil(oldest); XCTAssertNotNil(newest)
        let records = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(records.count, OpenAPIPriceDiskCache.maximumEntries)
        let totalBytes = try records.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(totalBytes, OpenAPIPriceDiskCache.maximumTotalBytes)
        let future = now.addingTimeInterval(60)
        cache.store(.init(data: body(set: 6), etag: nil, fetchedAt: future, validatedAt: future), for: url(6), now: now)
        let futureResult = cache.entry(for: url(6), now: now)
        XCTAssertNil(futureResult)
        let futureProviderBody = Data(String(decoding: body(set: 9), as: UTF8.self)
            .replacingOccurrences(of: "2026-01-29T16:50:40Z", with: "2099-01-29T16:50:40Z").utf8)
        cache.store(.init(data: futureProviderBody, etag: nil, fetchedAt: now, validatedAt: now), for: url(9), now: now)
        let futureProviderResult = cache.entry(for: url(9), now: now)
        XCTAssertNil(futureProviderResult)
        cache.store(.init(data: Data(repeating: 32, count: OpenAPIPriceDiskCache.maximumEntryBytes + 1), etag: nil, fetchedAt: now, validatedAt: now), for: url(7), now: now)
        let oversized = cache.entry(for: url(7), now: now)
        XCTAssertNil(oversized)
        let secretURL = URL(string: "https://openapi.tcgtracking.com/v1/3/sets/8/skus?token=private")!
        cache.store(.init(data: body(set: 8), etag: nil, fetchedAt: now, validatedAt: now), for: secretURL, now: now)
        let rejectedURL = cache.entry(for: secretURL, now: now)
        XCTAssertNil(rejectedURL)
    }

    func testCorruptedDiskRecordIsDiscardedAndTransportErrorIsPreserved() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.response(200, body(), nil)]), now: { now }, cacheDirectory: folder)
        _ = try await seed.quote(for: card())
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files { try Data("corrupt".utf8).write(to: file, options: .atomic) }
        let pricing = OpenAPIMarketPricing(resolver: OfflineCacheSetResolver(), loader: OfflineCacheLoader([.failure(URLError(.notConnectedToInternet))]), now: { now.addingTimeInterval(901) }, cacheDirectory: folder)
        do { _ = try await pricing.details(for: card(), candidates: [], forceRefresh: true); XCTFail("Corrupt cache data cannot become an offline quote") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testOfflineMetadataRemainsBackwardsDecodableAndShowsOriginalTime() async throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let original = MarketPriceMetadata(source: .openAPI, fetchedAt: fetched)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "isOffline")
        let restored = try JSONDecoder().decode(MarketPriceMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.isOffline)
        XCTAssertEqual(restored.summary, "Open API")
        var offline = restored; offline.isOffline = true
        XCTAssertTrue(offline.summary.lowercased().contains("cached"))
        XCTAssertTrue(offline.summary.lowercased().contains("offline"))
        XCTAssertTrue(offline.summary.contains(fetched.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertEqual(try JSONDecoder().decode(MarketPriceMetadata.self, from: JSONEncoder().encode(offline)), offline)
    }
}

private struct OfflineCacheSetResolver: OpenAPISetResolving {
    func setID(for card: CardCandidate) async throws -> Int? { 1 }
}

private actor OfflineCacheLoader: OpenAPIHTTPDataLoading {
    enum Result: @unchecked Sendable {
        case response(Int, Data, String?)
        case failure(Error)
    }
    private var results: [Result]
    private(set) var requests: [URLRequest] = []
    init(_ results: [Result]) { self.results = results }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !results.isEmpty else { throw URLError(.notConnectedToInternet) }
        switch results.removeFirst() {
        case .failure(let error): throw error
        case .response(let status, let data, let etag):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: etag.map { ["ETag": $0] })!)
        }
    }
}

private actor OfflineCachePendingLoader: OpenAPIHTTPDataLoading {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var started = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw URLError(.timedOut)
    }
    func fail() { continuation?.resume(throwing: URLError(.notConnectedToInternet)); continuation = nil }
}
