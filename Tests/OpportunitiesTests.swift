import XCTest
@testable import CardShowScanner

@MainActor final class OpportunitiesTests: XCTestCase {
    private let credentials = DirectResearchCredentials(shipperID: "fixture-shipper", apiKey: "fixture-api-key")
    private let instant = Date(timeIntervalSince1970: 1_790_000_000)

    private func card() -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", skuID: "100", printing: "1st Edition Holofoil"),
                      name: "Fixture", set: "Untrusted display set name", number: "42", marketPrice: 7,
                      confidence: 99, printings: ["1st Edition Holofoil"])
    }
    private func sku(_ id: String = "101", fields: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["sku_id": id, "condition_id": 1, "condition": "Near Mint",
            "finish": "1st Edition Holofoil", "language": "English",
            "timestamps": ["tcgp_sales_updated_at": "2026-10-29T01:00:00Z", "last_verified_at": "2026-10-29T02:00:00Z"],
            "pricing": ["market_sku": "8.50", "avg_30d": "8.00", "listed_low_card": "5.00", "listed_low_ship": "1.00", "listed_low_total": "6.00"],
            "trends": ["updated_at": "2026-10-29T01:00:00Z", "windows": [
                "30d": ["tcg_qty": 3, "tcg_sold_avg": "9.00", "tcg_sold_avg_with_sh": "10.00", "tcg_market_avg": "8.00", "mp_qty": 2, "mp_avg": "7.50", "combined_qty": 5],
                "90d": ["tcg_qty": 12, "tcg_sold_avg": "8.00", "combined_qty": 12],
                "365d": ["tcg_qty": 99, "tcg_sold_avg": NSNull(), "combined_qty": 99]]],
            "marketplaces": ["tcgplayer": ["available": true, "total_qty_available": 4, "updated_at": "2026-10-29T02:00:00Z", "listings": [
                ["rank": 1, "price": "5.00", "ship_price": "1.00", "landed_price": "6.00", "seller_qty": 4, "updated_at": "2026-10-29T02:00:00Z"]]]]]
        result.merge(fields) { _, new in new }; return result
    }
    private func fixture(category: Int = 3, group: Int = 1430, product: Int = 42,
                         skus: [String: [String: Any]]? = nil, normalized: Bool = false, missingProduct: Bool = false) throws -> Data {
        let selected: [String: Any] = ["product_id": product, "name": "Fixture", "skus": skus ?? ["101": sku()]]
        var body: [String: Any] = ["meta": ["category_id": category, "group_id": group, "schema_version": "2.0", "generated_at": "2026-10-29T02:00:00Z"]]
        if normalized { body["product"] = selected }
        else { body["products"] = missingProduct ? [:] : ["42": selected] }
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func decode(_ data: Data, card selected: CardCandidate? = nil) throws -> OpportunitiesDetails {
        try OpportunitiesDetails.decodeSet(data, for: selected ?? card(), expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }

    func testFixedDirectRequestExactSKUAndReportedSalesDoNotChangeSavedPrice() async throws {
        let loader = OpportunitiesLoader([.init(data: try fixture())]), saved = card()
        let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: OpportunitiesSetCache(), cadence: nil)
        let result = try await client.opportunities(for: saved, forceRefresh: false)
        let requests = await loader.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://beta.tcgtracking.com/v1/3/sets/1430")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shipper-Id"), credentials.shipperID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), credentials.apiKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(result.selectedSKUID, "101"); XCTAssertEqual(result.sku.skuID, "101")
        XCTAssertEqual(result.sku.finish, saved.identity.printing); XCTAssertEqual(result.sku.condition, "Near Mint")
        XCTAssertEqual(result.sku.trends?.windows["30d"]?.tcgQuantity, 3)
        XCTAssertEqual(result.sku.trends?.windows["30d"]?.tcgSoldAverage, 9)
        XCTAssertEqual(result.sku.trends?.windows["90d"]?.tcgQuantity, 12)
        XCTAssertEqual(result.sku.trends?.windows["365d"]?.tcgQuantity, 99)
        XCTAssertNil(result.sku.trends?.windows["365d"]?.tcgSoldAverage)
        XCTAssertEqual(result.sku.pricing?.listedLowCard, 5); XCTAssertEqual(result.sku.pricing?.listedLowShipping, 1)
        XCTAssertEqual(result.sku.pricing?.listedLowTotal, 6)
        XCTAssertEqual(result.sku.marketplaces["tcgplayer"]?.totalQuantityAvailable, 4)
        XCTAssertEqual(result.sku.marketplaces["tcgplayer"]?.listings.first?.shipping, 1)
        XCTAssertEqual(result.sku.timestamps?.tcgSalesUpdatedAt, "2026-10-29T01:00:00Z")
        XCTAssertEqual(saved.marketPrice, 7); XCTAssertEqual(saved.identity.skuID, "100")
    }

    func testMissingValuesStayMissingAndBlendedAverageDoesNotBecomeSoldAverage() throws {
        let fields: [String: Any] = ["pricing": ["market_sku": "0", "avg_30d": "7.00", "live_market": "NaN", "listed_low_card": true],
            "trends": ["windows": ["30d": ["tcg_qty": 0, "tcg_sold_avg": NSNull(), "mp_qty": -1, "combined_qty": true], "365d": [:]]],
            "marketplaces": ["tcgplayer": ["total_qty_available": 0, "listings": [["price": "0", "ship_price": NSNull(), "seller_qty": "0"]]]]]
        let result = try decode(fixture(skus: ["101": sku(fields: fields)]))
        XCTAssertEqual(result.sku.pricing?.marketSKU, 0); XCTAssertEqual(result.sku.pricing?.average30Days, 7)
        XCTAssertNil(result.sku.pricing?.liveMarket); XCTAssertNil(result.sku.pricing?.listedLowCard)
        XCTAssertEqual(result.sku.trends?.windows["30d"]?.tcgQuantity, 0)
        XCTAssertNil(result.sku.trends?.windows["30d"]?.tcgSoldAverage)
        XCTAssertNil(result.sku.trends?.windows["30d"]?.manapoolQuantity)
        XCTAssertNil(result.sku.trends?.windows["30d"]?.combinedQuantity)
        XCTAssertNil(result.sku.trends?.windows["90d"])
        XCTAssertNil(result.sku.trends?.windows["365d"]?.tcgQuantity)
        XCTAssertEqual(result.sku.marketplaces["tcgplayer"]?.totalQuantityAvailable, 0)
        XCTAssertEqual(result.sku.marketplaces["tcgplayer"]?.listings.first?.price, 0)
        XCTAssertNil(result.sku.marketplaces["tcgplayer"]?.listings.first?.shipping)
    }

    func testProviderPercentagesPreserveNegativeZeroAndMissingWithoutInventingTrends() throws {
        let trendFields: [String: Any] = ["trend_30d_vs_90d_pct": "-12", "trend_90d_pct": 0, "tcg_mp_trend_30d_pct": NSNull()]
        let result = try decode(fixture(skus: ["101": sku(fields: ["trends": trendFields])]))
        XCTAssertEqual(result.sku.trends?.trend30DaysVersus90DaysPercent, -12)
        XCTAssertEqual(result.sku.trends?.trend90DaysPercent, 0)
        XCTAssertNil(result.sku.trends?.tcgMPTrend30DaysPercent)
        let invalidValues: [Any] = [true, 32_768, -32_769, 1.5, "NaN", "1.5"]
        for invalid in invalidValues {
            let invalidTrend: [String: Any] = ["trend_30d_vs_90d_pct": invalid]
            let result = try decode(fixture(skus: ["101": sku(fields: ["trends": invalidTrend])]))
            XCTAssertNil(result.sku.trends?.trend30DaysVersus90DaysPercent)
            XCTAssertNil(result.sku.trends?.trend90DaysPercent)
        }
    }

    func testFullPrintingLanguageConditionAndSavedSKUCannotSubstituteAnotherIdentity() throws {
        let differentContexts: [[String: Any]] = [["finish": "Holofoil"], ["finish": "Unlimited Holofoil"], ["language": "Japanese"],
                                                ["condition_id": 2, "condition": "Lightly Played"]]
        for fields in differentContexts {
            XCTAssertThrowsError(try decode(fixture(skus: ["100": sku("100", fields: fields)]))) {
                XCTAssertEqual($0 as? OpportunitiesFailure, .skuNotCovered)
            }
        }
        XCTAssertThrowsError(try decode(fixture(skus: ["101": sku(fields: ["condition": "Lightly Played"])]))) {
            XCTAssertEqual($0 as? OpportunitiesFailure, .invalidResponse)
        }
        // A source-specific saved SKU may be stale; the sole exact context wins.
        XCTAssertEqual(try decode(fixture()).selectedSKUID, "101")
        let duplicate = try fixture(skus: ["101": sku(), "102": sku("102")])
        XCTAssertThrowsError(try decode(duplicate)) { XCTAssertEqual($0 as? OpportunitiesFailure, .skuNotCovered) }
        var selected = card(); selected.identity.skuID = "102"
        XCTAssertEqual(try decode(duplicate, card: selected).selectedSKUID, "102")
        selected.identity.skuID = "100"
        let wrongSaved = try fixture(skus: ["101": sku(), "100": sku("100", fields: ["language": "Japanese"])])
        XCTAssertEqual(try decode(wrongSaved, card: selected).selectedSKUID, "101")
    }

    func testMalformedAndWrongCatalogIdentitiesAreRejected() throws {
        for data in [Data("{}".utf8), Data("[]".utf8), try fixture(category: 1), try fixture(group: 1), try fixture(product: 43),
                     try fixture(skus: ["101": sku("102")]), try fixture(skus: ["bad": sku("101")]),
                     try fixture(skus: ["101": sku(fields: ["sku_id": true])])] {
            XCTAssertThrowsError(try decode(data)) { XCTAssertEqual($0 as? OpportunitiesFailure, .invalidResponse) }
        }
        XCTAssertThrowsError(try decode(fixture(missingProduct: true))) { XCTAssertEqual($0 as? OpportunitiesFailure, .notCovered) }
        let nullID = try decode(fixture(skus: ["101": sku(fields: ["sku_id": NSNull()])]))
        XCTAssertEqual(nullID.selectedSKUID, "101"); XCTAssertNil(nullID.sku.skuID)
    }

    func testDirectMetaTestsOpportunitiesIndependentlyFromResearch() async throws {
        let loader = OpportunitiesLoader([.init(data: Data("{\"categories\":{}}".utf8))])
        try await DirectOpportunitiesClient(credentials: credentials, loader: loader, cache: OpportunitiesSetCache(), cadence: nil).testConnection()
        let requests = await loader.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://beta.tcgtracking.com/v1/meta")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Api-Key"), credentials.apiKey)
        for reply in [OpportunitiesLoader.Reply(data: Data("{}".utf8)), .init(data: Data("[]".utf8)),
                      .init(data: Data("{\"categories\":{}}".utf8), url: URL(string: "https://untrusted.example/meta"))] {
            do { try await DirectOpportunitiesClient(credentials: credentials, loader: OpportunitiesLoader([reply]), cache: OpportunitiesSetCache(), cadence: nil).testConnection(); XCTFail("Malformed meta") }
            catch { XCTAssertEqual(error as? OpportunitiesFailure, .invalidResponse) }
        }
    }

    func testHTTPFailuresHaveSafeDistinctClassificationsAndNeverFollowRedirects() async throws {
        let cases: [(OpportunitiesLoader.Reply, OpportunitiesFailure)] = [
            (.init(status: 401), .directAuthorizationRequired), (.init(status: 403), .accessDenied),
            (.init(status: 404), .notCovered), (.init(status: 429), .rateLimited), (.init(status: 503), .serviceUnavailable(503)),
            (.init(status: 304), .invalidResponse), (.init(status: 302), .serviceUnavailable(302)),
            (.init(data: try fixture(), url: URL(string: "https://untrusted.example/set")), .invalidResponse),
            (.init(data: Data(repeating: 32, count: OpportunitiesDetails.maximumBytes + 1)), .responseTooLarge)]
        for (reply, expected) in cases {
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: OpportunitiesLoader([reply]), cache: OpportunitiesSetCache(), cadence: nil)
            do { _ = try await client.opportunities(for: card(), forceRefresh: false); XCTFail("Explicit failure") }
            catch { XCTAssertEqual(error as? OpportunitiesFailure, expected) }
        }
        let raw = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: FailingOpportunitiesLoader(), cache: OpportunitiesSetCache(), cadence: nil)
        do { _ = try await raw.opportunities(for: card(), forceRefresh: false); XCTFail("Transport failure") }
        catch {
            XCTAssertEqual(error as? OpportunitiesFailure, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains(credentials.apiKey))
        }
    }

    func testUnsupportedIdentityAndUnsafeCredentialsNeverReachTheService() async throws {
        let loader = OpportunitiesLoader([])
        for reference in ["mock:42", "p:42?key=secret", "https://example.com/product/42", "p:0"] {
            var selected = card(); selected.identity.productID = reference
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: OpportunitiesSetCache(), cadence: nil)
            do { _ = try await client.opportunities(for: selected, forceRefresh: false); XCTFail("Unsupported product") }
            catch { XCTAssertEqual(error as? OpportunitiesFailure, .unsupportedCard) }
        }
        let unknown = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(nil), loader: loader, cache: OpportunitiesSetCache(), cadence: nil)
        do { _ = try await unknown.opportunities(for: card(), forceRefresh: false); XCTFail("Unknown set") }
        catch { XCTAssertEqual(error as? OpportunitiesFailure, .catalogUnavailable) }
        let unsafe = DirectOpportunitiesClient(credentials: .init(shipperID: "id", apiKey: "key\r\ninjected"), loader: loader, cadence: nil)
        do { try await unsafe.testConnection(); XCTFail("Unsafe headers") }
        catch { XCTAssertEqual(error as? OpportunitiesFailure, .directNotConfigured) }
        let requests = await loader.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testServerUsesOnlyOriginBoundDeviceTokenAndNormalizesSameExactSKU() async throws {
        let token = String(repeating: "d", count: 32), loader = OpportunitiesLoader([.init(data: try fixture(normalized: true))])
        let client = OpportunitiesClient(baseURL: URL(string: "https://server.example")!, token: token,
            resolver: OpportunitiesResolver(1430), loader: loader, cache: OpportunitiesSetCache())
        let result = try await client.opportunities(for: card(), forceRefresh: true)
        let requests = await loader.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://server.example/api/v1/opportunities/3/1430/42")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertEqual(result.selectedSKUID, "101")
        let denied = OpportunitiesClient(baseURL: URL(string: "https://server.example")!, token: token,
            resolver: OpportunitiesResolver(1430), loader: OpportunitiesLoader([.init(status: 401)]), cache: OpportunitiesSetCache())
        do { _ = try await denied.opportunities(for: card(), forceRefresh: false); XCTFail("Device token") }
        catch { XCTAssertEqual(error as? OpportunitiesFailure, .authorizationRequired) }
    }

    func testHourlySetCacheAndETag304AreAccountSeparated() async throws {
        let loader = OpportunitiesLoader([.init(data: try fixture(), headers: ["ETag": "\"v1\""]), .init(status: 304), .init(data: try fixture())])
        let cache = OpportunitiesSetCache(), firstDate = instant, later = instant.addingTimeInterval(3_601)
        let first = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { firstDate })
        _ = try await first.opportunities(for: card(), forceRefresh: false)
        _ = try await first.opportunities(for: card(), forceRefresh: true)
        let expired = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { later })
        _ = try await expired.opportunities(for: card(), forceRefresh: true)
        let other = DirectOpportunitiesClient(credentials: .init(shipperID: credentials.shipperID, apiKey: "other-key"),
            resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { later })
        _ = try await other.opportunities(for: card(), forceRefresh: false)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Api-Key"), "other-key")
    }

    func testRetryAfterCooldownDoesNotLoopAndSeparatesAccounts() async throws {
        for status in [429, 503] {
            let loader = OpportunitiesLoader([.init(status: status, headers: ["Retry-After": "120"]), .init(data: try fixture()), .init(data: try fixture())])
            let cache = OpportunitiesSetCache(), start = instant, after = instant.addingTimeInterval(121)
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { start })
            for _ in 0..<2 {
                do { _ = try await client.opportunities(for: card(), forceRefresh: true); XCTFail("Cooldown") }
                catch { XCTAssertEqual(error as? OpportunitiesFailure, status == 429 ? .rateLimited : .serviceUnavailable(503)) }
            }
            var requests = await loader.requests; XCTAssertEqual(requests.count, 1)
            let other = DirectOpportunitiesClient(credentials: .init(shipperID: "other", apiKey: "other"), resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { start })
            _ = try await other.opportunities(for: card(), forceRefresh: false)
            let resumed = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { after })
            _ = try await resumed.opportunities(for: card(), forceRefresh: false)
            requests = await loader.requests; XCTAssertEqual(requests.count, 3)
        }
    }

    func testStaleSetIsNotUsedOnFailureAnd404DropsItsValidator() async throws {
        let loader = OpportunitiesLoader([.init(data: try fixture(), headers: ["ETag": "\"v1\""]), .init(status: 503), .init(status: 404), .init(data: try fixture())])
        let cache = OpportunitiesSetCache(), start = instant, later = instant.addingTimeInterval(3_601)
        let first = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { start })
        _ = try await first.opportunities(for: card(), forceRefresh: false)
        let expired = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil, now: { later })
        let failures: [OpportunitiesFailure] = [.serviceUnavailable(503), .notCovered]
        for expected in failures {
            do { _ = try await expired.opportunities(for: card(), forceRefresh: false); XCTFail("No stale fallback") }
            catch { XCTAssertEqual(error as? OpportunitiesFailure, expected) }
        }
        _ = try await expired.opportunities(for: card(), forceRefresh: false)
        let requests = await loader.requests
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testCacheRetainsAtMostFourBoundedBodies() async throws {
        let loader = OpportunitiesLoader(try (1...5).map { .init(data: try fixture(group: $0)) }), cache = OpportunitiesSetCache()
        for group in 1...5 {
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(group), loader: loader, cache: cache, cadence: nil)
            _ = try await client.opportunities(for: card(), forceRefresh: false)
        }
        let count = await cache.cachedEntryCount; XCTAssertEqual(count, 4)
    }

    func testCanceledOrClearedLateReplyCannotReturnOrRepopulateCache() async throws {
        for cancel in [true, false] {
            let loader = ControlledOpportunitiesLoader(), cache = OpportunitiesSetCache()
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: loader, cache: cache, cadence: nil)
            let selected = card(), pending = Task { try await client.opportunities(for: selected, forceRefresh: false) }
            try await loader.waitUntilStarted()
            if cancel { pending.cancel() } else { await cache.clear() }
            await loader.complete(with: try fixture())
            do { _ = try await pending.value; XCTFail("Late reply") }
            catch { XCTAssertTrue(error is CancellationError) }
            let count = await cache.cachedEntryCount; XCTAssertEqual(count, 0)
        }
    }

    func testNewRequestSupersedesOlderReplyForSameAccountAndSet() async throws {
        let oldLoader = ControlledOpportunitiesLoader(), newLoader = OpportunitiesLoader([.init(data: try fixture())]), cache = OpportunitiesSetCache()
        let old = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: oldLoader, cache: cache, cadence: nil)
        let selected = card(), pending = Task { try await old.opportunities(for: selected, forceRefresh: false) }
        try await oldLoader.waitUntilStarted()
        let newer = DirectOpportunitiesClient(credentials: credentials, resolver: OpportunitiesResolver(1430), loader: newLoader, cache: cache, cadence: nil)
        _ = try await newer.opportunities(for: selected, forceRefresh: false)
        await oldLoader.complete(with: try fixture())
        do { _ = try await pending.value; XCTFail("Older reply") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await cache.cachedEntryCount; XCTAssertEqual(count, 1)
    }
}

private struct OpportunitiesResolver: OpenAPISetResolving {
    let group: Int?
    init(_ group: Int?) { self.group = group }
    func setID(for card: CardCandidate) async throws -> Int? { group }
}

private actor OpportunitiesLoader: ResearchHTTPDataLoading {
    struct Reply: Sendable { var status = 200; var data = Data(); var url: URL?; var headers: [String: String] = [:] }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}

private actor ControlledOpportunitiesLoader: ResearchHTTPDataLoading {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var url: URL?
    private let started = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        url = request.url
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.continuation.yield(true)
            started.continuation.finish()
        }
    }
    func waitUntilStarted() async throws {
        if continuation != nil { return }
        let notification = started.stream
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in notification { return }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    func complete(with data: Data) {
        continuation?.resume(returning: (data, HTTPURLResponse(url: url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        continuation = nil
    }
}

private struct FailingOpportunitiesLoader: ResearchHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw NSError(domain: "fixture-api-key", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture-api-key / private raw response"])
    }
}
