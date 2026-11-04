import XCTest
@testable import CardShowScanner

/// These synthetic responses verify category routing, not live provider coverage.
@MainActor final class TCGGamePricingTests: XCTestCase {
    private let games: [(name: String, category: Int)] = [
        ("One Piece Card Game", 68), ("Disney Lorcana", 71),
        ("Riftbound: League of Legends Trading Card Game", 89), ("Pokemon Japan", 85)
    ]

    private func card(game: String, language: String = "English", condition: String = "Near Mint") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: game, productID: "p:512035", printing: "Normal",
            language: language, condition: condition), name: "Fixture Card", set: "Fixture Set", number: "001",
            marketPrice: nil, confidence: 95, printings: ["Normal"])
    }

    private func product(category: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "success": true, "product_id": 512035,
            "product": ["product_id": 512035, "category_id": category, "group_id": category + 1000,
                "name": "Fixture Card", "set_name": "Fixture Set", "ext_number": "001",
                "image_url": "https://cdn.tcgtracking.com/product/512035_200w.jpg"]
        ])
    }

    private func skus() -> Data {
        Data(#"""
        {"set_id":123,"updated":"2026-11-04T09:35:00-05:00","products":{"512035":{
          "1":{"cnd":"NM","var":"Normal","lng":"EN","mkt":"4.25"},
          "2":{"cnd":"LP","var":"Normal","lng":"EN","mkt":0},
          "3":{"cnd":"NM","var":"Normal","lng":"JP","mkt":"7.50"},
          "4":{"cnd":"LP","var":"Normal","lng":"JP","mkt":0}
        }}}
        """#.utf8)
    }

    func testPricingCategoriesKeepLegacyNamesAndRecognizeUploadedGamesOnly() {
        let legacy: [(name: String, category: Int)] = [("Pokémon", 3), ("Magic: The Gathering", 1), ("Yu-Gi-Oh!", 2)]
        for game in legacy + games {
            XCTAssertEqual(OpenAPIMarketPricing.categoryID(game.name), game.category)
        }
        XCTAssertEqual(OpenAPIMarketPricing.categoryID("Pokémon Japan"), 85)
        XCTAssertNil(OpenAPIMarketPricing.categoryID("Unsupported Game"))
        XCTAssertFalse(TCGGameRegistry.isProductCategory(999999))
    }

    func testExpandedGamesRequestTheirOwnSKUShardAndReuseExactConditionsAndLanguages() async throws {
        for game in games {
            let loader = TCGGamePricingLoader([.init(data: skus())])
            let pricing = OpenAPIMarketPricing(resolver: TCGGamePricingResolver(), loader: loader, cacheDirectory: nil)
            let japanese = game.category == 85
            var selected = card(game: game.name, language: japanese ? "Japanese" : "English")
            let nearMint = try await pricing.quote(for: selected)
            XCTAssertEqual(nearMint, MarketQuote(marketPrice: Decimal(string: japanese ? "7.50" : "4.25"),
                skuID: japanese ? "3" : "1"))
            selected.identity.condition = "Lightly Played"
            let played = try await pricing.quote(for: selected)
            XCTAssertEqual(played, MarketQuote(marketPrice: 0, skuID: japanese ? "4" : "2"))
            selected.identity.condition = "Damaged"
            let unavailable = try await pricing.quote(for: selected)
            XCTAssertNil(unavailable, "Missing conditions cannot reuse the Near Mint price")
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 1, "The same cached daily shard includes every condition")
            XCTAssertEqual(requests.first?.url?.absoluteString,
                "https://openapi.tcgtracking.com/v1/\(game.category)/sets/123/skus")
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        }
    }

    func testExpandedProductMetadataSurvivesRestartAndIsIsolatedByExactCategory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let replies = try games.map { TCGGamePricingLoader.Reply(data: product(category: $0.category)) }
        let loader = TCGGamePricingLoader(replies)
        let first = OpenAPIProductLookup(loader: loader, now: { fetchedAt }, cacheDirectory: folder)
        for game in games {
            let metadata = try await first.product(for: "512035", categoryID: game.category)
            XCTAssertEqual(metadata.categoryID, game.category)
            XCTAssertEqual(metadata.groupID, game.category + 1000)
        }
        let requests = await loader.requests
        XCTAssertEqual(requests.count, games.count, "The same product ID cannot cross category cache namespaces")
        XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString == "https://openapi.tcgtracking.com/v1/products/512035" })

        let offlineLoader = TCGGamePricingLoader(offline: true)
        let restarted = OpenAPIProductLookup(loader: offlineLoader,
            now: { fetchedAt.addingTimeInterval(8 * 24 * 60 * 60) }, cacheDirectory: folder)
        for game in games {
            let metadata = try await restarted.product(for: "512035", categoryID: game.category)
            XCTAssertEqual(metadata.categoryID, game.category)
            XCTAssertEqual(metadata.groupID, game.category + 1000)
        }
        let attempts = await offlineLoader.requests
        XCTAssertEqual(attempts.count, games.count, "Expired metadata is revalidated before an offline fallback")
    }

    func testKnownCategoriesStillRejectCrossCategoryResponsesUnknownCategoriesAndChangedURLs() async throws {
        let onePiece = try product(category: 68)
        XCTAssertThrowsError(try OpenAPIProductLookup.parse(onePiece, productID: "512035", categoryID: 71)) {
            XCTAssertEqual($0 as? OpenAPIPricingFailure, .invalidResponse)
        }
        XCTAssertThrowsError(try OpenAPIProductLookup.parse(product(category: 999999), productID: "512035", categoryID: 999999)) {
            XCTAssertEqual($0 as? OpenAPIPricingFailure, .invalidResponse)
        }
        let unused = TCGGamePricingLoader()
        let lookup = OpenAPIProductLookup(loader: unused, cacheDirectory: nil)
        do {
            _ = try await lookup.product(for: "512035", categoryID: 999999)
            XCTFail("Unregistered categories must be rejected before making a request")
        } catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .unsupportedCard) }
        let unusedRequests = await unused.requests
        XCTAssertTrue(unusedRequests.isEmpty)

        let redirected = TCGGamePricingLoader([.init(data: onePiece,
            url: URL(string: "https://openapi.tcgtracking.com/v1/products/512036"))])
        let strict = OpenAPIProductLookup(loader: redirected, cacheDirectory: nil)
        do {
            _ = try await strict.product(for: "512035", categoryID: 68)
            XCTFail("A response for another URL cannot establish product metadata")
        } catch { XCTAssertEqual(error as? OpenAPIPricingFailure, .invalidResponse) }
    }

    func testNativeSetResolverUsesEachExpandedGamesOwnPublishedManifest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ScannerDatabaseCache(directory: folder)
        let resolver = NativeOpenAPISetResolver(cache: cache)
        for game in games {
            let path = "fixture-\(game.category)/manifest.json"
            let meta = "fixture-\(game.category)/set.meta"
            try await cache.write("m:" + meta, data: tagged([
                "refs": [["p:512035", "Fixture Card", "001", "FX", "Fixture Set"]]
            ]))
            try await cache.write("M:" + path, data: tagged([
                "v": 2, "shards": [["group_id": game.category + 1000, "meta": "set.meta"]]
            ]))
            try await cache.write("cur:tcgp:\(game.category)", data: tagged(path))
        }
        for game in games {
            let set = try await resolver.setID(for: card(game: game.name))
            XCTAssertEqual(set, game.category + 1000)
        }
        let unsupported = try await resolver.setID(for: card(game: "Unsupported Game"))
        XCTAssertNil(unsupported)
    }

    func testBetaIndexAcceptsExpandedCategoriesAndKeepsDataAndHTTPETagsSeparate() async throws {
        let categories = Dictionary(uniqueKeysWithValues: games.map { game in
            (String(game.category), ["sets": ["123": ["etag": "data-\(game.category)"]]])
        })
        let index = try JSONSerialization.data(withJSONObject: ["categories": categories])
        let credentials = DirectResearchCredentials(shipperID: "fixture-shipper", apiKey: "fixture-key")
        for family in [BetaAPIFamily.opportunities, .research] {
            let cadence = BetaAPICadence()
            let loader = TCGGamePricingLoader([
                .init(data: index, headers: ["ETag": "\"http-body\""]), .init(status: 304)
            ])
            for game in games {
                let info = try await cadence.setInfo(family: family, category: game.category, group: 123,
                    credentials: credentials, loader: loader)
                XCTAssertEqual(info.dataETag, "data-\(game.category)")
            }
            let revalidated = try await cadence.setInfo(family: family, category: 68, group: 123,
                forceRefresh: true, credentials: credentials, loader: loader)
            XCTAssertEqual(revalidated.dataETag, "data-68")
            do {
                _ = try await cadence.setInfo(family: family, category: 999999, group: 123,
                    credentials: credentials, loader: loader)
                XCTFail("Unregistered Beta categories must be rejected")
            } catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .invalidRequest) }
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 2, "Category changes reuse the daily family metadata index")
            XCTAssertEqual(requests.first?.url?.path, family == .research ? "/v1/research/meta" : "/v1/meta")
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"http-body\"")
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "If-None-Match") == "data-68" })
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Shipper-Id"), credentials.shipperID)
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Api-Key"), credentials.apiKey)
        }
    }

    private func tagged(_ object: Any) throws -> Data {
        var result = Data([0])
        result.append(try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
        return result
    }
}

private struct TCGGamePricingResolver: OpenAPISetResolving {
    func setID(for card: CardCandidate) async throws -> Int? { 123 }
}

private actor TCGGamePricingLoader: OpenAPIHTTPDataLoading, ResearchHTTPDataLoading {
    struct Reply: Sendable {
        var data = Data()
        var status = 200
        var headers: [String: String] = [:]
        var url: URL?
    }
    private var replies: [Reply]
    private let offline: Bool
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply] = [], offline: Bool = false) { self.replies = replies; self.offline = offline }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers)!)
    }
}
