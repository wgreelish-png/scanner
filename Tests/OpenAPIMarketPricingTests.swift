import XCTest
@testable import CardShowScanner

@MainActor final class OpenAPIMarketPricingTests: XCTestCase {
    private func card(_ ref: String = "p:15038", printing: String = "Normal", condition: String = "Near Mint", language: String = "English", game: String = "Pokémon") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: game, productID: ref, printing: printing, language: language, condition: condition),
                      name: "Fixture", set: "Fixture", number: "1", marketPrice: nil, confidence: 95, printings: [printing])
    }
    private func body(_ rows: String, extra: String = "", updated: String = "2026-01-29T11:50:40-05:00") -> Data {
        Data("{\"set_id\":1,\"updated\":\"\(updated)\",\"products\":{\"15038\":{\(rows)}\(extra)}}".utf8)
    }
    private let exactRows = #"""
    "4639":{"cnd":"NM","var":"Normal","var_a":"N","vid":1,"lng":"EN","mkt":0.34,"low":0.25},
    "4640":{"cnd":"LP","var":"Normal","lng":"EN","mkt":"0.27"},
    "4641":{"cnd":"NM","var":"Foil","lng":"EN","mkt":4.54},
    "4642":{"cnd":"NM","var":"Normal","lng":"JP","mkt":2.15}
    """#
    func testExactSKUConditionLanguageAndFullPrinting() async throws {
        let data = body(exactRows)
        let normal = try OpenAPIMarketPricing.parseDetails(data, for: card())
        XCTAssertEqual(normal.quote, MarketQuote(marketPrice: Decimal(string: "0.34"), skuID: "4639"))
        XCTAssertEqual(normal.context, MarketPriceContext(lowPrice: Decimal(string: "0.25"), highPrice: nil, listingCount: nil))
        XCTAssertEqual(try OpenAPIMarketPricing.parseDetails(data, for: card(condition: "Lightly Played")).quote,
                       MarketQuote(marketPrice: Decimal(string: "0.27"), skuID: "4640"))
        XCTAssertEqual(try OpenAPIMarketPricing.parseDetails(data, for: card(printing: "  FOIL  ")).quote?.skuID, "4641")
        XCTAssertEqual(try OpenAPIMarketPricing.parseDetails(data, for: card(language: "Japanese")).quote?.skuID, "4642")
        for unsupported in [card(printing: "N"), card(printing: "Holofoil"), card(condition: "Moderately Played"), card(language: "German"), card(language: "Chinese")] {
            let details = try OpenAPIMarketPricing.parseDetails(data, for: unsupported)
            XCTAssertNil(details.quote)
            XCTAssertNil(details.context)
        }
    }
    func testComparableContextUsesOnlyTheExactSKURowAndPreservesZero() async throws {
        let rows = #""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":null,"low":0,"hi":"0.50","cnt":0},"4640":{"cnd":"LP","var":"Normal","lng":"EN","mkt":4,"low":9,"hi":10,"cnt":99}"#
        let details = try OpenAPIMarketPricing.parseDetails(body(rows), for: card())
        XCTAssertEqual(details.quote, MarketQuote(marketPrice: nil, skuID: "4639"))
        XCTAssertEqual(details.context, MarketPriceContext(lowPrice: 0, highPrice: Decimal(string: "0.50"), listingCount: 0))
        let played = try OpenAPIMarketPricing.parseDetails(body(rows), for: card(condition: "Lightly Played"))
        XCTAssertEqual(played.context, MarketPriceContext(lowPrice: 9, highPrice: 10, listingCount: 99))
        let ambiguous = rows + #", "9999":{"cnd":"NM","var":"Normal","lng":"EN","mkt":null,"low":0,"hi":"0.50","cnt":0}"#
        let duplicate = try OpenAPIMarketPricing.parseDetails(body(ambiguous), for: card())
        XCTAssertNil(duplicate.quote); XCTAssertNil(duplicate.context)
    }
    func testInvalidOptionalComparablesAreMissingWithoutInvalidatingMarketPrice() async throws {
        let invalid = ["null", "true", "-1", "\"-1\"", "\"NaN\"", "\"Infinity\"", "{}", "[]"]
        for value in invalid {
            let rows = "\"4639\":{\"cnd\":\"NM\",\"var\":\"Normal\",\"lng\":\"EN\",\"mkt\":1.25,\"low\":\(value),\"hi\":\(value),\"cnt\":\(value)}"
            let details = try OpenAPIMarketPricing.parseDetails(body(rows), for: card())
            XCTAssertEqual(details.quote, MarketQuote(marketPrice: Decimal(string: "1.25"), skuID: "4639"), value)
            XCTAssertNil(details.context, value)
        }
        for value in ["1.25", "\"1.25\"", "\"9223372036854775808\""] {
            let rows = "\"4639\":{\"cnd\":\"NM\",\"var\":\"Normal\",\"lng\":\"EN\",\"mkt\":1.25,\"low\":0.50,\"cnt\":\(value)}"
            let details = try OpenAPIMarketPricing.parseDetails(body(rows), for: card())
            XCTAssertEqual(details.context, MarketPriceContext(lowPrice: Decimal(string: "0.50"), highPrice: nil, listingCount: nil), value)
        }
        let missing = try OpenAPIMarketPricing.parseDetails(body(#""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":1.25}"#), for: card())
        XCTAssertNil(missing.context)
        let stringCount = try OpenAPIMarketPricing.parseDetails(body(#""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":1.25,"cnt":"8"}"#), for: card())
        XCTAssertEqual(stringCount.context?.listingCount, 8)
    }
    func testEveryDocumentedConditionAndLanguageHasAnExactMapping() async throws {
        let conditions = [("Near Mint", "NM"), ("Lightly Played", "LP"), ("Moderately Played", "MP"), ("Heavily Played", "HP"), ("Damaged", "DMG")]
        let languages = [("English", "EN"), ("Japanese", "JP"), ("French", "FR"), ("German", "DE"), ("Italian", "IT"), ("Spanish", "ES"),
                         ("Portuguese", "PT"), ("Russian", "RU"), ("Korean", "KO"), ("Simplified Chinese", "CS"), ("Traditional Chinese", "CT")]
        var rows: [String: [String: String]] = [:]
        for (conditionIndex, condition) in conditions.enumerated() {
            for (languageIndex, language) in languages.enumerated() {
                rows[String(1_000 + conditionIndex * 100 + languageIndex)] = ["cnd": condition.1, "lng": language.1, "var": "1st Edition Holofoil", "mkt": "1.25"]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["set_id": 1, "products": ["15038": rows]])
        for (conditionIndex, condition) in conditions.enumerated() {
            for (languageIndex, language) in languages.enumerated() {
                let quote = try OpenAPIMarketPricing.parseDetails(data, for: card(printing: "1st Edition Holofoil", condition: condition.0, language: language.0)).quote
                XCTAssertEqual(quote?.skuID, String(1_000 + conditionIndex * 100 + languageIndex))
            }
        }
        XCTAssertNil(try OpenAPIMarketPricing.parseDetails(data, for: card(printing: "Holofoil")).quote)
    }
    func testMissingNullZeroAndInvalidPricesPreserveSKUWithoutFallbacks() async throws {
        let cases: [(String, Decimal?)] = [("0", Decimal.zero), ("\"0.125\"", Decimal(string: "0.125")), ("null", nil), ("-1", nil),
                                  ("true", nil), ("\"NaN\"", nil), ("\"Infinity\"", nil), ("\"1,234\"", nil), ("\"2 dollars\"", nil), ("\"-1.00\"", nil), ("\"1e1000\"", nil)]
        for (value, expected) in cases {
            let rows = "\"4639\":{\"cnd\":\"NM\",\"var\":\"Normal\",\"lng\":\"EN\",\"mkt\":\(value),\"low\":99,\"mp\":88}"
            let quote = try OpenAPIMarketPricing.parseDetails(body(rows), for: card()).quote
            XCTAssertEqual(quote, MarketQuote(marketPrice: expected, skuID: "4639"), value)
        }
        let missing = #""4639":{"cnd":"NM","var":"Normal","lng":"EN","low":99}"#
        XCTAssertEqual(try OpenAPIMarketPricing.parseDetails(body(missing), for: card()).quote, MarketQuote(marketPrice: nil, skuID: "4639"))
    }
    func testAmbiguousExactSKUsAreUnavailableEvenWithSavedSKUID() async throws {
        let duplicate = exactRows + #", "9999":{"cnd":"NM","var":"Normal","lng":"EN","mkt":0.34}"#
        var selected = card(); selected.identity.skuID = "4639"
        XCTAssertNil(try OpenAPIMarketPricing.parseDetails(body(duplicate), for: selected).quote)
    }
    func testFrozenCandidatesReceiveOnlyTheirReturnedPrintingOptionsAndMetadata() async throws {
        let extra = #", "2":{"5":{"cnd":"NM","var":"Reverse Holofoil","lng":"EN","mkt":null}}, "3":{"6":{"cnd":"NM","var":"Secret","lng":"EN","mkt":3}}"#
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let details = try OpenAPIMarketPricing.parseDetails(body(exactRows, extra: extra), for: card(printing: "Missing"), candidates: [card("p:2")], fetchedAt: fetched)
        XCTAssertNil(details.quote)
        XCTAssertEqual(Set(details.printings), ["Normal", "Foil"])
        XCTAssertEqual(details.printingsByProduct["p:2"], ["Reverse Holofoil"])
        XCTAssertNil(details.printingsByProduct["p:3"])
        XCTAssertEqual(details.metadata?.source, .openAPI)
        XCTAssertEqual(details.metadata?.fetchedAt, fetched)
        XCTAssertEqual(details.metadata?.updatedAt, ISO8601DateFormatter().date(from: "2026-01-29T11:50:40-05:00"))
        XCTAssertNil(try OpenAPIMarketPricing.parseDetails(body(exactRows), for: card("p:999")).metadata)
    }
    func testNamespaceAndGamesAreCheckedBeforeResolvingOrLoading() async throws {
        let loader = PricingHTTPLoader([])
        let resolver = PricingSetResolver(set: 1)
        let pricing = OpenAPIMarketPricing(resolver: resolver, loader: loader, cacheDirectory: nil)
        for selected in [card("t:15038"), card("ts:15038"), card("u:15038"), card("p:15038?x"), card("p:15038\n"), card(game: "Other")] {
            do { _ = try await pricing.quote(for: selected); XCTFail("Unsupported identity should throw") }
            catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .unsupportedCard) }
        }
        let calls = await loader.requests.count; let resolutions = await resolver.calls
        XCTAssertEqual(calls, 0); XCTAssertEqual(resolutions, 0)
        let unmapped = OpenAPIMarketPricing(resolver: PricingSetResolver(set: nil), loader: loader, cacheDirectory: nil)
        do { _ = try await unmapped.quote(for: card()); XCTFail("Missing set must be explicit") }
        catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .catalogUnavailable) }
    }
    func testCacheReusesAllConditionsThenForcesConditional304WithoutChangingDailyTimestamp() async throws {
        let clock = PricingClock(Date(timeIntervalSince1970: 1_800_000_000))
        let loader = PricingHTTPLoader([.init(status: 200, data: body(exactRows), etag: "\"daily-1\""), .init(status: 304)])
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, now: { clock.read() }, cacheDirectory: nil)
        let first = try await pricing.details(for: card(), candidates: [], forceRefresh: false)
        let played = try await pricing.quote(for: card(condition: "Lightly Played"))
        XCTAssertEqual(played?.skuID, "4640")
        var count = await loader.requests.count; XCTAssertEqual(count, 1)
        clock.advance(60)
        let revalidated = try await pricing.details(for: card(), candidates: [], forceRefresh: true)
        XCTAssertEqual(revalidated.quote, first.quote)
        XCTAssertEqual(revalidated.metadata?.updatedAt, first.metadata?.updatedAt)
        XCTAssertEqual(revalidated.metadata?.fetchedAt, clock.read())
        let requests = await loader.requests; count = requests.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"daily-1\"")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://openapi.tcgtracking.com/v1/3/sets/1/skus")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization")); XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }
    func testDatasetCacheKeepsOnlyFourSets() async throws {
        let clock = PricingClock(Date())
        let replies = (Array(1...5) + [1]).map { set in
            PricingHTTPLoader.Reply(status: 200, data: Data(String(decoding: body(exactRows), as: UTF8.self).replacingOccurrences(of: "\"set_id\":1", with: "\"set_id\":\(set)").utf8))
        }
        let loader = PricingHTTPLoader(replies)
        let pricing = OpenAPIMarketPricing(resolver: CardSetPricingResolver(), loader: loader, now: { clock.read() }, cacheDirectory: nil)
        for set in Array(1...5) + [1] {
            var selected = card(); selected.set = String(set)
            _ = try await pricing.quote(for: selected)
            clock.advance(1)
        }
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 6, "The oldest of five set bodies should have been evicted")
    }
    func testExpiredAndFailedForcedRefreshNeverReturnStaleQuote() async throws {
        let clock = PricingClock(Date())
        let loader = PricingHTTPLoader([.init(status: 200, data: body(exactRows)), .init(status: 503), .init(status: 403), .init(status: 503)])
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, now: { clock.read() }, cacheDirectory: nil)
        _ = try await pricing.quote(for: card()); clock.advance(901)
        for (force, status) in [(false, 503), (true, 403), (false, 503)] {
            do { _ = try await pricing.details(for: card(), candidates: [], forceRefresh: force); XCTFail("Stale body must not be a fallback") }
            catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .httpStatus(status)) }
        }
        let count = await loader.requests.count; XCTAssertEqual(count, 4)
    }
    func testMalformedMismatchedRedirectedAndOversizedResponsesAreRejected() async throws {
        let cases: [(PricingHTTPLoader.Reply, OpenAPIPricingFailure)] = [
            (.init(status: 304), .invalidResponse),
            (.init(status: 200, data: Data("{}".utf8)), .invalidResponse),
            (.init(status: 200, data: Data("{\"set_id\":2,\"products\":{}}".utf8)), .invalidResponse),
            (.init(status: 200, data: body(exactRows), url: URL(string: "https://example.com/")), .invalidResponse),
            (.init(status: 302), .httpStatus(302)),
            (.init(status: 200, data: Data(repeating: 32, count: NativeOpenAPIHTTPDataLoader.maximumBytes + 1)), .responseTooLarge)
        ]
        for (reply, failure) in cases {
            let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: PricingHTTPLoader([reply]), cacheDirectory: nil)
            do { _ = try await pricing.quote(for: card()); XCTFail("Invalid response should throw") }
            catch { XCTAssertEqual(error as? OpenAPIPricingFailure, failure) }
        }
    }
    func testNativeURLPolicyRejectsCredentialsQueriesFragmentsAndOtherPaths() async {
        XCTAssertTrue(NativeOpenAPIHTTPDataLoader.allows(URL(string: "https://openapi.tcgtracking.com/v1/3/sets/1/skus")))
        for url in ["http://openapi.tcgtracking.com/v1/3/sets/1/skus", "https://openapi.tcgtracking.com.evil/v1/3/sets/1/skus",
                    "https://user:secret@openapi.tcgtracking.com/v1/3/sets/1/skus", "https://openapi.tcgtracking.com/v1/3/sets/1/pricing",
                    "https://openapi.tcgtracking.com/v1/3/sets/1/skus?token=secret", "https://openapi.tcgtracking.com/v1/3/sets/1/skus#x"] {
            XCTAssertFalse(NativeOpenAPIHTTPDataLoader.allows(URL(string: url)))
        }
    }
    func testOrdinaryOverlappingLookupsShareTheSetRequest() async throws {
        let loader = ControlledPricingLoader()
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, cacheDirectory: nil)
        let normal = card(), foil = card(printing: "Foil")
        let first = Task { try await pricing.quote(for: normal) }
        try await loader.waitForCalls(1)
        let second = Task { try await pricing.quote(for: foil) }
        // Give the second independent consumer time to join the in-flight set request.
        try await Task.sleep(for: .milliseconds(10))
        await loader.complete(0, data: body(exactRows))
        let firstQuote = try await first.value, secondQuote = try await second.value
        XCTAssertEqual(firstQuote?.skuID, "4639"); XCTAssertEqual(secondQuote?.skuID, "4641")
        let calls = await loader.callCount
        XCTAssertEqual(calls, 1)
    }
    func testCancellingJoinedConsumerReturnsBeforeTheOwnerFinishes() async throws {
        let loader = ControlledPricingLoader()
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, cacheDirectory: nil)
        let selected = card()
        let owner = Task { try await pricing.quote(for: selected) }
        try await loader.waitForCalls(1)
        var finished = false
        let joined = Task {
            do { _ = try await pricing.quote(for: selected); XCTFail("Cancelled consumer must not return a quote") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished = true
        }
        try await Task.sleep(for: .milliseconds(10)); joined.cancel()
        for _ in 0..<100 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(finished, "Cancellation should remove a joined waiter without waiting for network completion")
        await loader.complete(0, data: body(exactRows))
        _ = try await owner.value; await joined.value
    }
    func testCancellingRequestOwnerAllowsAnActiveJoinedConsumerToRetry() async throws {
        let loader = ControlledPricingLoader()
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, cacheDirectory: nil)
        let selected = card()
        let owner = Task { try await pricing.quote(for: selected) }
        try await loader.waitForCalls(1)
        let joined = Task { try await pricing.quote(for: selected) }
        try await Task.sleep(for: .milliseconds(10)); owner.cancel()
        await loader.fail(0, error: URLError(.cancelled))
        do { _ = try await owner.value; XCTFail("Owner must remain cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        try await loader.waitForCalls(2)
        await loader.complete(1, data: body(exactRows))
        let quote = try await joined.value
        XCTAssertEqual(quote?.skuID, "4639")
    }
    func testLaterForcedResponseWinsAndCancelledResponseNeverEntersCache() async throws {
        let loader = ControlledPricingLoader()
        let pricing = OpenAPIMarketPricing(resolver: PricingSetResolver(set: 1), loader: loader, cacheDirectory: nil)
        let selected = card()
        let first = Task { try await pricing.details(for: selected, candidates: [], forceRefresh: true) }
        try await loader.waitForCalls(1)
        let second = Task { try await pricing.details(for: selected, candidates: [], forceRefresh: true) }
        try await loader.waitForCalls(2)
        await loader.complete(1, data: body(#""4639":{"cnd":"NM","var":"Normal","lng":"EN","mkt":2}"#))
        let latest = try await second.value
        XCTAssertEqual(latest.quote?.marketPrice, 2)
        await loader.complete(0, data: body(exactRows))
        do { _ = try await first.value; XCTFail("Superseded response must be discarded") } catch { XCTAssertTrue(error is CancellationError) }
        let cached = try await pricing.quote(for: selected)
        XCTAssertEqual(cached?.marketPrice, 2)
        let cancelled = Task { try await pricing.details(for: selected, candidates: [], forceRefresh: true) }
        try await loader.waitForCalls(3); cancelled.cancel()
        await loader.complete(2, data: body(exactRows))
        do { _ = try await cancelled.value; XCTFail("Cancelled response must be discarded") } catch { XCTAssertTrue(error is CancellationError) }
        let retry = Task { try await pricing.quote(for: selected) }
        try await loader.waitForCalls(4)
        await loader.complete(3, data: body(exactRows))
        let recovered = try await retry.value
        XCTAssertEqual(recovered?.marketPrice, Decimal(string: "0.34"))
    }
}

private actor PricingSetResolver: OpenAPISetResolving {
    let set: Int?
    private(set) var calls = 0
    init(set: Int?) { self.set = set }
    func setID(for card: CardCandidate) -> Int? { calls += 1; return set }
}
private actor PricingHTTPLoader: OpenAPIHTTPDataLoading {
    struct Reply: Sendable {
        var status: Int; var data = Data(); var etag: String? = nil; var url: URL? = nil
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil,
                                            headerFields: reply.etag.map { ["ETag": $0] })!)
    }
}
private final class PricingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}
private actor ControlledPricingLoader: OpenAPIHTTPDataLoading {
    private var continuations: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var urls: [Int: URL] = [:]
    private var calls = 0
    var callCount: Int { calls }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = calls; calls += 1; urls[call] = request.url!
        return try await withCheckedThrowingContinuation { continuations[call] = $0 }
    }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<500 {
            if calls >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw URLError(.timedOut)
    }
    func fail(_ call: Int, error: Error) {
        continuations.removeValue(forKey: call)?.resume(throwing: error)
    }
    func complete(_ call: Int, data: Data) {
        continuations.removeValue(forKey: call)?.resume(returning: (data, HTTPURLResponse(url: urls[call]!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

private struct CardSetPricingResolver: OpenAPISetResolving {
    func setID(for card: CardCandidate) async throws -> Int? { Int(card.set) }
}
