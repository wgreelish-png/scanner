import XCTest
@testable import CardShowScanner

@MainActor final class DirectResearchTests: XCTestCase {
    private let credentials = DirectResearchCredentials(shipperID: "fixture-shipper", apiKey: "fixture-api-key")
    private let instant = Date(timeIntervalSince1970: 1_790_000_000)

    private func card(_ ref: String = "p:42", game: String = "Pokémon") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: game, productID: ref, printing: "Holofoil", language: "English"),
                      name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 7,
                      confidence: 99, printings: ["Holofoil"])
    }
    private func fixture(product: Int = 42, group: Int = 1430, category: Int = 3, missingProduct: Bool = false, dataHash: String? = nil) throws -> Data {
        let selected: [String: Any] = ["product_id": product, "name": "Fixture card", "ext_number": "42",
            "variants": ["EN:Holofoil": ["language": "EN", "finish": "Holofoil", "grades": [
                ["grader": "PSA", "grade": "10", "guide_value": 0, "market_value": NSNull(), "pop": 0, "sales": 2]]]]]
        var meta: [String: Any] = ["category_id": category, "group_id": group, "schema_version": "2.0-testing", "status": "in_testing"]
        if let dataHash { meta["etag"] = dataHash }
        return try JSONSerialization.data(withJSONObject: [
            "meta": meta,
            "products": missingProduct ? [:] : ["42": selected]
        ])
    }

    private func index(dataHash: String?) throws -> Data {
        var set: [String: Any] = ["product_count": 1, "grade_row_count": 1]
        if let dataHash { set["etag"] = dataHash }
        return try JSONSerialization.data(withJSONObject: ["categories": ["3": ["sets": ["1430": set]]]])
    }

    func testCredentialsAreBoundedHeaderSafeAndDescriptionsAreRedacted() async throws {
        let valid = try DirectResearchCredentials.validated(shipperID: " fixture-shipper ", apiKey: " fixture-api-key ")
        XCTAssertEqual(valid, credentials)
        for rendered in [String(describing: valid), String(reflecting: valid), valid.debugDescription] {
            XCTAssertFalse(rendered.contains(valid.shipperID)); XCTAssertFalse(rendered.contains(valid.apiKey))
        }
        for (shipper, key) in [("", "key"), ("id", ""), ("a\nb", "key"), ("id", "a\r\nb"),
                               ("has space", "key"), ("id", "é"), (String(repeating: "x", count: 129), "key"),
                               ("id", String(repeating: "x", count: 513))] {
            XCTAssertThrowsError(try DirectResearchCredentials.validated(shipperID: shipper, apiKey: key)) {
                XCTAssertEqual($0 as? ResearchFailure, .directNotConfigured)
            }
        }
    }

    func testDirectRequestUsesOnlyFixedBetaOriginAndExactProductWithoutChangingSavedPrice() async throws {
        let loader = DirectLoader([.init(data: try fixture())]), saved = card()
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: DirectResearchSetCache(), cadence: nil)
        let result = try await client.research(for: saved, forceRefresh: false)
        let requests = await loader.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://beta.tcgtracking.com/v1/3/sets/1430/research")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shipper-Id"), credentials.shipperID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), credentials.apiKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.url?.query); XCTAssertEqual(result.product.productID, 42)
        let grade = try XCTUnwrap(result.product.variants["EN:Holofoil"]?.grades.first)
        XCTAssertEqual(grade.guideValue, 0); XCTAssertNil(grade.marketValue); XCTAssertEqual(grade.population, 0)
        XCTAssertEqual(saved.marketPrice, 7, "Research must not replace inventory quotes")
    }

    func testConnectionUsesAuthenticatedMetaAndDoesNotClaimProductCoverage() async throws {
        let loader = DirectLoader([.init(data: Data("{}".utf8))])
        let client = DirectResearchClient(credentials: credentials, loader: loader, cache: DirectResearchSetCache(), cadence: nil)
        try await client.testConnection()
        let requests = await loader.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://beta.tcgtracking.com/v1/research/meta")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), credentials.apiKey)
    }

    func testUnsupportedIdentityMissingSetAndInvalidCredentialsDoNotMakeRequests() async throws {
        let loader = DirectLoader([])
        for selected in [card("mock:42"), card("p:42?leak"), card(game: "Other")] {
            let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: DirectResearchSetCache(), cadence: nil)
            do { _ = try await client.research(for: selected, forceRefresh: false); XCTFail("Unsupported card") }
            catch { XCTAssertEqual(error as? ResearchFailure, .unsupportedCard) }
        }
        let unknown = DirectResearchClient(credentials: credentials, resolver: DirectResolver(nil), loader: loader, cache: DirectResearchSetCache(), cadence: nil)
        do { _ = try await unknown.research(for: card(), forceRefresh: false); XCTFail("Missing set") }
        catch { XCTAssertEqual(error as? ResearchFailure, .catalogUnavailable) }
        let unsafe = DirectResearchClient(credentials: .init(shipperID: "id", apiKey: "unsafe\r\nheader"), loader: loader, cadence: nil)
        do { try await unsafe.testConnection(); XCTFail("Unsafe credentials") }
        catch { XCTAssertEqual(error as? ResearchFailure, .directNotConfigured) }
        let requests = await loader.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testDirectAuthCoverageSchemaIdentityAndRedirectFailuresStayExplicit() async throws {
        let cases: [(DirectLoader.Reply, ResearchFailure)] = [
            (.init(status: 401), .directAuthorizationRequired), (.init(status: 403), .accessDenied),
            (.init(status: 404), .notCovered), (.init(status: 503), .serviceUnavailable(503)),
            (.init(status: 304), .invalidResponse), (.init(data: Data("{}".utf8)), .invalidResponse),
            (.init(data: try fixture(missingProduct: true)), .notCovered),
            (.init(data: try fixture(product: 43)), .invalidResponse),
            (.init(data: try fixture(group: 1)), .invalidResponse),
            (.init(data: try fixture(category: 1)), .invalidResponse),
            (.init(data: try fixture(), url: URL(string: "https://other.example.com/research")), .invalidResponse),
            (.init(data: Data(repeating: 32, count: DirectResearchClient.maximumSetBytes + 1)), .responseTooLarge)
        ]
        for (reply, expected) in cases {
            let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: DirectLoader([reply]), cache: DirectResearchSetCache(), cadence: nil)
            do { _ = try await client.research(for: card(), forceRefresh: false); XCTFail("Must fail explicitly") }
            catch { XCTAssertEqual(error as? ResearchFailure, expected) }
        }
    }

    func testConnectionRejectsDeniedMalformedAndRedirectedMetaResponses() async throws {
        for (reply, expected) in [(DirectLoader.Reply(status: 401), ResearchFailure.directAuthorizationRequired),
                                  (.init(status: 403), .accessDenied), (.init(data: Data("[]".utf8)), .invalidResponse),
                                  (.init(data: Data("{}".utf8), url: URL(string: "https://other.example.com/meta")), .invalidResponse)] {
            let client = DirectResearchClient(credentials: credentials, loader: DirectLoader([reply]), cache: DirectResearchSetCache(), cadence: nil)
            do { try await client.testConnection(); XCTFail("Unverified metadata must not pass") }
            catch { XCTAssertEqual(error as? ResearchFailure, expected) }
        }
    }

    func testHourlyCacheReusesSetButIsolatesCredentialsAndDoesNotBypassCadenceOnRefresh() async throws {
        let loader = DirectLoader([.init(data: try fixture()), .init(data: try fixture())]), cache = DirectResearchSetCache()
        let now = instant
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: cache, now: { now }, cadence: nil)
        _ = try await client.research(for: card(), forceRefresh: false)
        _ = try await client.research(for: card(), forceRefresh: true)
        let other = DirectResearchClient(credentials: .init(shipperID: credentials.shipperID, apiKey: "another-key"), resolver: DirectResolver(1430), loader: loader, cache: cache, now: { now }, cadence: nil)
        _ = try await other.research(for: card(), forceRefresh: false)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 2, "A fresh same-account set does not redownload for each card/refresh")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Api-Key"), "another-key")
    }

    func testExpiredCacheUsesHTTPETagAnd304RevalidatesTheExactSet() async throws {
        let loader = DirectLoader([.init(data: try fixture(), headers: ["ETag": "\"fixture-v1\""]), .init(status: 304)])
        let cache = DirectResearchSetCache(), firstDate = instant, expired = instant.addingTimeInterval(3_601)
        let first = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: cache, now: { firstDate }, cadence: nil)
        _ = try await first.research(for: card(), forceRefresh: false)
        let second = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: cache, now: { expired }, cadence: nil)
        let result = try await second.research(for: card(), forceRefresh: true)
        _ = try await second.research(for: card(), forceRefresh: false)
        XCTAssertEqual(result.product.productID, 42)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"fixture-v1\"")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testExpiredSetIsNotSilentlyReturnedWhenProviderFails() async throws {
        let loader = DirectLoader([.init(data: try fixture()), .init(status: 503)])
        let cache = DirectResearchSetCache(), firstDate = instant, expired = instant.addingTimeInterval(3_601)
        let first = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: cache, now: { firstDate }, cadence: nil)
        _ = try await first.research(for: card(), forceRefresh: false)
        let second = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: cache, now: { expired }, cadence: nil)
        do { _ = try await second.research(for: card(), forceRefresh: false); XCTFail("Stale data must not look freshly verified") }
        catch { XCTAssertEqual(error as? ResearchFailure, .serviceUnavailable(503)) }
    }

    func testCanceledDirectNetworkResponseCannotReturnResearch() async throws {
        let loader = ControlledDirectLoader()
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader, cache: DirectResearchSetCache(), cadence: nil)
        let selected = card(), pending = Task { try await client.research(for: selected, forceRefresh: false) }
        try await loader.waitUntilStarted(); pending.cancel(); await loader.complete(with: try fixture())
        do { _ = try await pending.value; XCTFail("A late canceled reply must be ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransportFailuresDoNotPublishRawCredentialBearingErrors() async throws {
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430),
                                          loader: FailingDirectLoader(), cache: DirectResearchSetCache(), cadence: nil)
        do { _ = try await client.research(for: card(), forceRefresh: false); XCTFail("Network failure") }
        catch {
            XCTAssertEqual(error as? ResearchFailure, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains(credentials.apiKey))
        }
    }

    func testDailyIndexAndEqualDataHashSkipShardBeyondHourlyWindowAndOnManualRefresh() async throws {
        let hash = String(repeating: "a", count: 32), clock = DirectCadenceClock(instant)
        let loader = DirectLoader([
            .init(data: try index(dataHash: hash), headers: ["ETag": "\"index-http-a\""]),
            .init(data: try fixture(dataHash: hash), headers: ["ETag": "\"shard-http-a\""]),
            .init(status: 304), .init(status: 304)
        ])
        let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                          cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
        let first = try await client.research(for: card(), forceRefresh: false)
        clock.advance(3_601)
        let ordinary = try await client.research(for: card(), forceRefresh: false)
        XCTAssertEqual(ordinary, first)
        var requests = await loader.requests
        XCTAssertEqual(requests.count, 2, "A cached daily index with an unchanged data hash must skip the hourly shard request")
        let manual = try await client.research(for: card(), forceRefresh: true)
        XCTAssertEqual(manual, first)
        requests = await loader.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/v1/research/meta")
        XCTAssertEqual(requests[1].url?.path, "/v1/3/sets/1430/research")
        XCTAssertEqual(requests[2].url?.path, "/v1/research/meta")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-a\"")
        clock.advance(86_401)
        let nextDay = try await client.research(for: card(), forceRefresh: false)
        XCTAssertEqual(nextDay, first)
        requests = await loader.requests
        XCTAssertEqual(requests.count, 4, "An expired daily index must revalidate while an unchanged data hash still skips the shard")
        XCTAssertEqual(requests[3].url?.path, "/v1/research/meta")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-a\"")
    }

    func testChangedIndexDataHashFetchesFreshHourlyShardWithItsHTTPETag() async throws {
        let oldHash = String(repeating: "a", count: 32), newHash = String(repeating: "b", count: 32)
        let clock = DirectCadenceClock(instant)
        let loader = DirectLoader([
            .init(data: try index(dataHash: oldHash), headers: ["ETag": "\"index-http-a\""]),
            .init(data: try fixture(dataHash: oldHash), headers: ["ETag": "\"shard-body-http-a\""]),
            .init(data: try index(dataHash: newHash), headers: ["ETag": "\"index-http-b\""]),
            .init(data: try fixture(dataHash: newHash), headers: ["ETag": "\"shard-body-http-b\""])
        ])
        let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                          cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
        _ = try await client.research(for: card(), forceRefresh: false)
        clock.advance(60)
        _ = try await client.research(for: card(), forceRefresh: true)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 4, "Changed index data must bypass a still-fresh hourly shard")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-a\"")
        XCTAssertEqual(requests[3].url?.path, "/v1/3/sets/1430/research")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"shard-body-http-a\"")
        XCTAssertNotEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), oldHash)
        XCTAssertNotEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), newHash)
    }

    func testMissingIndexOrShardDataHashFallsBackToDailyHTTPRevalidation() async throws {
        let hash = String(repeating: "a", count: 32)
        let cases: [(String?, String?)] = [(nil, hash), (hash, nil)]
        for (indexHash, shardHash) in cases {
            let clock = DirectCadenceClock(instant)
            let loader = DirectLoader([
                .init(data: try index(dataHash: indexHash), headers: ["ETag": "\"index-http\""]),
                .init(data: try fixture(dataHash: shardHash), headers: ["ETag": "\"body-http\""]),
                .init(status: 304), .init(status: 304)
            ])
            let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
            let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                              cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
            _ = try await client.research(for: card(), forceRefresh: false)
            clock.advance(3_601)
            _ = try await client.research(for: card(), forceRefresh: false)
            var requests = await loader.requests; XCTAssertEqual(requests.count, 2)
            clock.advance(82_800)
            _ = try await client.research(for: card(), forceRefresh: false)
            requests = await loader.requests
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(requests[2].url?.path, "/v1/research/meta")
            XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"index-http\"")
            XCTAssertEqual(requests[3].url?.path, "/v1/3/sets/1430/research")
            XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"body-http\"")
        }
    }

    func testCadenceIndexAndShardCachesIsolateChangedAPIKeys() async throws {
        let hash = String(repeating: "a", count: 32), clock = DirectCadenceClock(instant)
        let loader = DirectLoader([
            .init(data: try index(dataHash: hash)), .init(data: try fixture(dataHash: hash)),
            .init(data: try index(dataHash: hash)), .init(data: try fixture(dataHash: hash))
        ])
        let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in }), cache = DirectResearchSetCache()
        let first = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                         cache: cache, now: { clock.read() }, cadence: cadence)
        _ = try await first.research(for: card(), forceRefresh: false)
        let otherCredentials = DirectResearchCredentials(shipperID: credentials.shipperID, apiKey: "rotated-fixture-key")
        let second = DirectResearchClient(credentials: otherCredentials, resolver: DirectResolver(1430), loader: loader,
                                          cache: cache, now: { clock.read() }, cadence: cadence)
        _ = try await second.research(for: card(), forceRefresh: false)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].url?.path, "/v1/research/meta")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Api-Key"), otherCredentials.apiKey)
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "X-Api-Key"), otherCredentials.apiKey)
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testPersistedResearchAndIndexSurviveRestartAndStayAccountIsolated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DirectResearchRestartTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hash = String(repeating: "a", count: 32), clock = DirectCadenceClock(instant)
        let seedLoader = DirectLoader([
            .init(data: try index(dataHash: hash), headers: ["ETag": "\"persisted-index-http\""]),
            .init(data: try fixture(dataHash: hash), headers: ["ETag": "\"persisted-shard-http\""])
        ])
        let seedDisk = BetaAPIDiskCache(directory: folder)
        let seedCadence = BetaAPICadence(now: { clock.read() }, wait: { _ in }, disk: seedDisk)
        let seed = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: seedLoader,
                                        cache: DirectResearchSetCache(disk: seedDisk), now: { clock.read() }, cadence: seedCadence)
        let original = try await seed.research(for: card(), forceRefresh: false)
        clock.advance(60)
        let restartDisk = BetaAPIDiskCache(directory: folder), offlineLoader = DirectLoader([])
        let restartCadence = BetaAPICadence(now: { clock.read() }, wait: { _ in }, disk: restartDisk)
        let restarted = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: offlineLoader,
                                             cache: DirectResearchSetCache(disk: restartDisk), now: { clock.read() }, cadence: restartCadence)
        let restored = try await restarted.research(for: card(), forceRefresh: false)
        XCTAssertEqual(restored, original)
        let offlineRequests = await offlineLoader.requests
        XCTAssertTrue(offlineRequests.isEmpty, "A same-account restart should reuse the verified daily index and its exact shard")
        let otherCredentials = DirectResearchCredentials(shipperID: credentials.shipperID, apiKey: "another-persisted-account-key")
        let otherLoader = DirectLoader([.init(data: try index(dataHash: hash)), .init(data: try fixture(dataHash: hash))])
        let otherDisk = BetaAPIDiskCache(directory: folder)
        let otherCadence = BetaAPICadence(now: { clock.read() }, wait: { _ in }, disk: otherDisk)
        let other = DirectResearchClient(credentials: otherCredentials, resolver: DirectResolver(1430), loader: otherLoader,
                                         cache: DirectResearchSetCache(disk: otherDisk), now: { clock.read() }, cadence: otherCadence)
        _ = try await other.research(for: card(), forceRefresh: false)
        let otherRequests = await otherLoader.requests
        XCTAssertEqual(otherRequests.count, 2)
        XCTAssertEqual(otherRequests[0].url?.path, "/v1/research/meta")
        XCTAssertEqual(otherRequests[1].url?.path, "/v1/3/sets/1430/research")
        for request in otherRequests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), otherCredentials.apiKey)
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        }
    }

    func testChangedIndexHashRejects304ForAnOldShardDataHash() async throws {
        let oldHash = String(repeating: "a", count: 32), newHash = String(repeating: "b", count: 32)
        let clock = DirectCadenceClock(instant)
        let loader = DirectLoader([
            .init(data: try index(dataHash: oldHash), headers: ["ETag": "\"index-http-old\""]),
            .init(data: try fixture(dataHash: oldHash), headers: ["ETag": "\"shard-http-old\""]),
            .init(data: try index(dataHash: newHash), headers: ["ETag": "\"index-http-new\""]),
            .init(status: 304, headers: ["ETag": "\"shard-http-new\""])
        ])
        let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                          cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
        _ = try await client.research(for: card(), forceRefresh: false)
        clock.advance(60)
        do { _ = try await client.research(for: card(), forceRefresh: true); XCTFail("An HTTP 304 cannot verify a shard whose data hash contradicts the changed index") }
        catch { XCTAssertEqual(error as? ResearchFailure, .invalidResponse) }
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-old\"")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"shard-http-old\"")
        XCTAssertNotEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), oldHash)
        XCTAssertNotEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), newHash)
    }

    func testForcedIndexFailuresDoNotBypassFreshShardCache() async throws {
        let hash = String(repeating: "a", count: 32)
        let failures: [(DirectLoader.Reply, ResearchFailure)] = [
            (.init(status: 401), .directAuthorizationRequired), (.init(status: 403), .accessDenied),
            (.init(status: 503), .serviceUnavailable(503)), (.init(data: Data("[]".utf8)), .invalidResponse)
        ]
        for (failure, expected) in failures {
            let clock = DirectCadenceClock(instant)
            let loader = DirectLoader([.init(data: try index(dataHash: hash)), .init(data: try fixture(dataHash: hash)), failure])
            let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
            let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                              cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
            _ = try await client.research(for: card(), forceRefresh: false)
            do { _ = try await client.research(for: card(), forceRefresh: true); XCTFail("A failed forced index check must remain visible") }
            catch { XCTAssertEqual(error as? ResearchFailure, expected) }
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.last?.url?.path, "/v1/research/meta")
        }
    }

    func testCancellingCadenceIndexCannotFetchOrReturnResearchShard() async throws {
        let loader = ControlledDirectLoader(), clock = DirectCadenceClock(instant)
        let cadence = BetaAPICadence(now: { clock.read() }, wait: { _ in })
        let client = DirectResearchClient(credentials: credentials, resolver: DirectResolver(1430), loader: loader,
                                          cache: DirectResearchSetCache(), now: { clock.read() }, cadence: cadence)
        let selected = card(), pending = Task { try await client.research(for: selected, forceRefresh: false) }
        try await loader.waitUntilStarted()
        pending.cancel()
        await loader.complete(with: try index(dataHash: String(repeating: "a", count: 32)))
        do { _ = try await pending.value; XCTFail("A cancelled index check cannot return a research shard") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/research/meta")
    }
}

private struct DirectResolver: OpenAPISetResolving {
    let group: Int?
    init(_ group: Int?) { self.group = group }
    func setID(for card: CardCandidate) async throws -> Int? { group }
}
private actor DirectLoader: ResearchHTTPDataLoading {
    struct Reply: Sendable {
        var status = 200
        var data = Data()
        var url: URL? = nil
        var headers: [String: String] = [:]
    }
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
private actor ControlledDirectLoader: ResearchHTTPDataLoading {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var url: URL?
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        url = request.url
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func complete(with data: Data) {
        continuation?.resume(returning: (data, HTTPURLResponse(url: url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        continuation = nil
    }
}
private struct FailingDirectLoader: ResearchHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw NSError(domain: "fixture-api-key", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture-api-key connection failed"])
    }
}

private final class DirectCadenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}
