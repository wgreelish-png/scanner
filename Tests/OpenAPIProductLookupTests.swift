import XCTest
@testable import CardShowScanner

@MainActor final class OpenAPIProductLookupTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenAPIProductLookupTests-" + UUID().uuidString, isDirectory: true)
    }
    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let resource = try XCTUnwrap(bundle.url(forResource: "OpenAPICharmanderProduct", withExtension: "json", subdirectory: "Fixtures") ??
                                     bundle.url(forResource: "OpenAPICharmanderProduct", withExtension: "json"))
        return try Data(contentsOf: resource)
    }
    private func productData(productID: Int = 512035, categoryID: Int = 3, groupID: Int = 23237,
                             name: String = "Charmander", setName: String = "SV: Scarlet & Violet 151", number: String = "004/165") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "success": true, "product_id": productID,
            "product": ["product_id": productID, "category_id": categoryID, "group_id": groupID,
                        "name": name, "set_name": setName, "ext_number": number,
                        "image_url": "https://cdn.tcgtracking.com/product/\(productID)_200w.jpg"],
            // Product-level aggregate values are deliberately unrelated to the exact SKU quote.
            "prices": ["market": 999, "low": 888]
        ])
    }
    private func card() -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:512035", printing: "Normal", language: "English", condition: "Lightly Played"),
                      name: "A display name cannot establish identity", set: "A display set cannot establish identity", number: "?",
                      marketPrice: nil, confidence: 95, printings: ["Normal"])
    }
    private func metadata(group: Int = 23237) -> OpenAPIProductMetadata {
        OpenAPIProductMetadata(productID: 512035, categoryID: 3, groupID: group, name: "Charmander", setName: "Fixture", number: "004/165", imageURL: nil)
    }

    func testCapturedCharmanderResponsePreservesExactProductAndCategory() async throws {
        let data = try fixtureData()
        let result = try OpenAPIProductLookup.parse(data, productID: "512035", categoryID: 3)
        XCTAssertEqual(result.productID, 512035)
        XCTAssertEqual(result.categoryID, 3)
        XCTAssertEqual(result.groupID, 22872)
        XCTAssertEqual(result.name, "Charmander - 044")
        XCTAssertEqual(result.setName, "SV: Scarlet & Violet Promo Cards")
        XCTAssertEqual(result.number, "044")
        XCTAssertEqual(result.imageURL?.absoluteString, "https://tcgplayer-cdn.tcgplayer.com/product/512035_200w.jpg")
        XCTAssertEqual(try JSONDecoder().decode(OpenAPIProductMetadata.self, from: JSONEncoder().encode(result)), result)
    }

    func testParserRejectsWrongRootProductNestedProductCategoryAndMissingGroup() async throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: productData()) as? [String: Any])
        var cases: [[String: Any]] = []
        var rootMismatch = original; rootMismatch["product_id"] = 1; cases.append(rootMismatch)
        for (key, value) in [("product_id", 1), ("category_id", 1), ("group_id", 0), ("group_id", -1)] {
            var response = original
            var product = try XCTUnwrap(response["product"] as? [String: Any]); product[key] = value
            response["product"] = product; cases.append(response)
        }
        var missingGroup = original
        var nested = try XCTUnwrap(missingGroup["product"] as? [String: Any]); nested.removeValue(forKey: "group_id")
        missingGroup["product"] = nested; cases.append(missingGroup)
        var unsuccessful = original; unsuccessful["success"] = false; cases.append(unsuccessful)
        var errorBody = original; errorBody["error"] = "product_not_found"; errorBody["success"] = false; cases.append(errorBody)
        for response in cases {
            XCTAssertThrowsError(try OpenAPIProductLookup.parse(JSONSerialization.data(withJSONObject: response), productID: "512035", categoryID: 3)) {
                XCTAssertEqual($0 as? OpenAPIPricingFailure, .invalidResponse)
            }
        }
        for invalidID in ["p:512035", "512035?token=private", "512035\n", "0", "-1", ""] {
            XCTAssertThrowsError(try OpenAPIProductLookup.parse(productData(), productID: invalidID, categoryID: 3))
        }
    }

    func testSevenDayMetadataReuseThenOnlineRefresh() async throws {
        let clock = ProductLookupClock(Date(timeIntervalSince1970: 1_800_000_000))
        let loader = ProductLookupLoader([.response(200, try productData()), .response(200, try productData(groupID: 99, setName: "Changed"))])
        let lookup = OpenAPIProductLookup(loader: loader, now: { clock.read() }, cacheDirectory: nil)
        let first = try await lookup.product(for: "512035", categoryID: 3)
        clock.advance(6 * 24 * 60 * 60)
        let reused = try await lookup.product(for: "512035", categoryID: 3)
        XCTAssertEqual(reused, first)
        var requests = await loader.requests; XCTAssertEqual(requests.count, 1)
        clock.advance(2 * 24 * 60 * 60)
        let refreshed = try await lookup.product(for: "512035", categoryID: 3)
        XCTAssertEqual(refreshed.groupID, 99)
        requests = await loader.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://openapi.tcgtracking.com/v1/products/512035")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
    }

    func testPersistentMetadataSurvivesRestartForOfflineSetResolution() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIProductLookup(loader: ProductLookupLoader([.response(200, try productData())]), now: { fetched }, cacheDirectory: folder)
        let original = try await seed.product(for: "512035", categoryID: 3)
        let loader = ProductLookupLoader([.failure(URLError(.notConnectedToInternet))])
        let restarted = OpenAPIProductLookup(loader: loader, now: { fetched.addingTimeInterval(8 * 24 * 60 * 60) }, cacheDirectory: folder)
        let restored = try await restarted.product(for: "512035", categoryID: 3)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.groupID, 23237)
    }

    func testExpiredMetadataDoesNotHideHTTPOrMalformedResponseFailures() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let seed = OpenAPIProductLookup(loader: ProductLookupLoader([.response(200, try productData())]), now: { fetched }, cacheDirectory: folder)
        _ = try await seed.product(for: "512035", categoryID: 3)
        for response in [ProductLookupLoader.Result.response(401, Data()), .response(404, Data()), .response(200, Data("{}".utf8))] {
            let lookup = OpenAPIProductLookup(loader: ProductLookupLoader([response]), now: { fetched.addingTimeInterval(8 * 24 * 60 * 60) }, cacheDirectory: folder)
            do { _ = try await lookup.product(for: "512035", categoryID: 3); XCTFail("Only connectivity failures may reuse expired metadata") }
            catch { XCTAssertTrue(error is OpenAPIPricingFailure) }
        }
    }

    func testMetadataMemoryCacheRetainsAtMost128Products() async throws {
        let clock = ProductLookupClock(Date(timeIntervalSince1970: 1_800_000_000))
        let count = OpenAPIProductLookup.maximumEntries + 1
        let replies = try (Array(1...count) + [1]).map { ProductLookupLoader.Result.response(200, try productData(productID: $0)) }
        let loader = ProductLookupLoader(replies)
        let lookup = OpenAPIProductLookup(loader: loader, now: { clock.read() }, cacheDirectory: nil)
        for productID in 1...count {
            _ = try await lookup.product(for: String(productID), categoryID: 3)
            clock.advance(1)
        }
        _ = try await lookup.product(for: "1", categoryID: 3)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, count + 1, "The oldest product should have been evicted once the bounded metadata cache fills")
    }

    func testHTTPFailuresRedirectsMalformedAndOversizedBodiesAreRejected() async throws {
        let valid = try productData()
        let cases: [ProductLookupLoader.Result] = [
            .response(401, valid), .response(403, valid), .response(404, valid), .response(302, valid),
            .response(200, Data("{}".utf8)),
            .redirected(valid, URL(string: "https://example.com/product")!),
            .response(200, Data(repeating: 32, count: NativeOpenAPIHTTPDataLoader.maximumBytes + 1))
        ]
        for result in cases {
            let lookup = OpenAPIProductLookup(loader: ProductLookupLoader([result]), cacheDirectory: nil)
            do { _ = try await lookup.product(for: "512035", categoryID: 3); XCTFail("Invalid product responses cannot establish a set mapping") }
            catch { XCTAssertTrue(error is OpenAPIPricingFailure) }
        }
    }

    func testResolverUsesLocalExactMappingBeforePublicMetadata() async throws {
        let local = ProductLookupLocalResolver(set: 42), lookup = ProductLookupSpy(metadata: metadata())
        let resolver = CatalogOpenAPISetResolver(local: local, lookup: lookup)
        let selected = card()
        let set = try await resolver.setID(for: selected)
        XCTAssertEqual(set, 42)
        let calls = await lookup.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testResolverFallbackRequestsExactProductAndUsesOnlyItsGroup() async throws {
        let lookup = ProductLookupSpy(metadata: metadata(group: 73))
        let resolver = CatalogOpenAPISetResolver(local: ProductLookupLocalResolver(set: nil), lookup: lookup)
        let set = try await resolver.setID(for: card())
        XCTAssertEqual(set, 73)
        let calls = await lookup.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.productID, "512035")
        XCTAssertEqual(calls.first?.categoryID, 3)
        var unsupported = card(); unsupported.identity.productID = "t:512035"
        let unsupportedSet = try await resolver.setID(for: unsupported)
        XCTAssertNil(unsupportedSet)
        let laterCalls = await lookup.calls
        XCTAssertEqual(laterCalls.count, 1)
    }

    func testResolverRejectsCrossProductMetadataAndDoesNotOverrideAmbiguousLocalMapping() async throws {
        var wrongProduct = metadata(); wrongProduct.productID = 1
        let wrongLookup = ProductLookupSpy(metadata: wrongProduct)
        let resolver = CatalogOpenAPISetResolver(local: ProductLookupLocalResolver(set: nil), lookup: wrongLookup)
        do { _ = try await resolver.setID(for: card()); XCTFail("Matching display metadata cannot replace a different exact product ID") }
        catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .invalidResponse) }
        let untouchedLookup = ProductLookupSpy(metadata: metadata())
        let ambiguous = CatalogOpenAPISetResolver(local: ProductLookupLocalResolver(set: 0), lookup: untouchedLookup)
        let set = try await ambiguous.setID(for: card())
        XCTAssertNil(set)
        let calls = await untouchedLookup.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRecoveredSetStillGetsExactSKUPriceInsteadOfProductAggregate() async throws {
        let productLoader = ProductLookupLoader([.response(200, try fixtureData())])
        let lookup = OpenAPIProductLookup(loader: productLoader, cacheDirectory: nil)
        let resolver = CatalogOpenAPISetResolver(local: ProductLookupLocalResolver(set: nil), lookup: lookup)
        // The captured product's aggregate market is 68.63. Only these exact
        // SKU rows establish the displayed condition and printing prices.
        let skus = Data(#"{"set_id":22872,"products":{"512035":{"7354291":{"cnd":"NM","var":"Holofoil","lng":"EN","mkt":"47.55","low":"7.99","hi":"61.32","cnt":25},"7354292":{"cnd":"LP","var":"Holofoil","lng":"EN","mkt":"42.70","low":"34.99","hi":"50.13","cnt":25},"102":{"cnd":"LP","var":"Normal","lng":"EN","mkt":200}}}}"#.utf8)
        let priceLoader = ProductLookupLoader([.response(200, skus)])
        let pricing = OpenAPIMarketPricing(resolver: resolver, loader: priceLoader, cacheDirectory: nil)
        var selected = card(); selected.identity.printing = "Holofoil"
        let details = try await pricing.details(for: selected, candidates: [], forceRefresh: false)
        XCTAssertEqual(details.quote, MarketQuote(marketPrice: Decimal(string: "42.70"), skuID: "7354292"))
        XCTAssertEqual(details.context, MarketPriceContext(lowPrice: Decimal(string: "34.99"), highPrice: Decimal(string: "50.13"), listingCount: 25))
        selected.identity.condition = "Near Mint"
        let nearMint = try await pricing.details(for: selected, candidates: [], forceRefresh: false)
        XCTAssertEqual(nearMint.quote, MarketQuote(marketPrice: Decimal(string: "47.55"), skuID: "7354291"))
        XCTAssertNotEqual(details.quote?.marketPrice, Decimal(string: "68.63"))
        XCTAssertNotEqual(nearMint.quote?.marketPrice, Decimal(string: "68.63"))
        let requests = await priceLoader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://openapi.tcgtracking.com/v1/3/sets/22872/skus")
    }

    func testCancellationRejectsLoaderThatReturnsAfterCancellation() async throws {
        let loader = ProductLookupPendingLoader()
        let lookup = OpenAPIProductLookup(loader: loader, cacheDirectory: nil)
        let pending = Task { try await lookup.product(for: "512035", categoryID: 3) }
        try await loader.waitUntilStarted()
        pending.cancel()
        await loader.complete(try productData())
        do { _ = try await pending.value; XCTFail("A cancelled product lookup cannot establish metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class ProductLookupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}
private actor ProductLookupLoader: OpenAPIHTTPDataLoading {
    enum Result: @unchecked Sendable {
        case response(Int, Data)
        case redirected(Data, URL)
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
        case .response(let status, let data): return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .redirected(let data, let url): return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
private struct ProductLookupLocalResolver: OpenAPISetResolving {
    var set: Int?
    func setID(for card: CardCandidate) async throws -> Int? { set }
}
private actor ProductLookupSpy: OpenAPIProductLookingUp {
    struct Call: Sendable { var productID: String; var categoryID: Int }
    var metadata: OpenAPIProductMetadata
    private(set) var calls: [Call] = []
    init(metadata: OpenAPIProductMetadata) { self.metadata = metadata }
    func product(for productID: String, categoryID: Int) async throws -> OpenAPIProductMetadata {
        calls.append(Call(productID: productID, categoryID: categoryID))
        return metadata
    }
}
private actor ProductLookupPendingLoader: OpenAPIHTTPDataLoading {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var requestURL: URL?
    private var started = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestURL = request.url; started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw URLError(.timedOut)
    }
    func complete(_ data: Data) {
        continuation?.resume(returning: (data, HTTPURLResponse(url: requestURL!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        continuation = nil
    }
}
