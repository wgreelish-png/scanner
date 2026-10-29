import XCTest
@testable import CardShowScanner

@MainActor final class BetaAPICadenceTests: XCTestCase {
    private let credentials = DirectResearchCredentials(shipperID: "fixture-shipper", apiKey: "fixture-key")

    private func request(_ path: String = "/v1/meta", method: String = "GET") -> URLRequest {
        var result = URLRequest(url: URL(string: "https://beta.tcgtracking.com" + path)!)
        result.httpMethod = method
        result.setValue(credentials.shipperID, forHTTPHeaderField: "X-Shipper-Id")
        result.setValue(credentials.apiKey, forHTTPHeaderField: "X-Api-Key")
        return result
    }
    private func index(_ hash: String? = "data-hash", category: String = "3", group: String = "1430") throws -> Data {
        var set: [String: Any] = [:]
        if let hash { set["etag"] = hash }
        return try JSONSerialization.data(withJSONObject: ["categories": [category: ["sets": [group: set]]]])
    }
    private func coordinator(_ clock: BetaCadenceClock) -> BetaAPICadence {
        BetaAPICadence(now: { clock.now() }, wait: { seconds in try Task.checkCancellation(); clock.waitAndAdvance(seconds) })
    }

    func testAccountNamespaceSeparatesCredentialsWithoutContainingThem() {
        let first = BetaAPICadence.account(for: credentials)
        XCTAssertEqual(first, BetaAPICadence.account(for: credentials))
        XCTAssertNotEqual(first, BetaAPICadence.account(for: .init(shipperID: credentials.shipperID, apiKey: "different-key")))
        XCTAssertNotEqual(first, BetaAPICadence.account(for: .init(shipperID: "different-shipper", apiKey: credentials.apiKey)))
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(first.contains(credentials.apiKey)); XCTAssertFalse(first.contains(credentials.shipperID))
    }

    func testShared120RequestBudgetCountsMetadataHeadAnd304AtTheExactBoundary() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader(Array(repeating: .init(status: 304), count: 121), clock: clock)
        for number in 0..<120 {
            let path = number.isMultiple(of: 2) ? "/v1/meta" : "/v1/research/meta"
            _ = try await cadence.send(request(path, method: number.isMultiple(of: 3) ? "HEAD" : "GET"), credentials: credentials, loader: loader)
        }
        XCTAssertTrue(clock.waits.isEmpty)
        clock.set(Date(timeIntervalSince1970: 1_259.5))
        _ = try await cadence.send(request("/v1/3/sets/1430"), credentials: credentials, loader: loader)
        XCTAssertEqual(clock.waits, [0.5])
        let times = await loader.times
        XCTAssertEqual(times.count, 121)
        XCTAssertEqual(times.last, Date(timeIntervalSince1970: 1_260))
    }

    func testProviderRemainingAndResetDelayTheNextRequestWithoutARealSleep() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(headers: ["X-RateLimit-Limit": "2", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "15"]), .init()], clock: clock)
        _ = try await cadence.send(request(), credentials: credentials, loader: loader)
        _ = try await cadence.send(request("/v1/3/sets/1430/research"), credentials: credentials, loader: loader)
        XCTAssertEqual(clock.waits, [15])
        let times = await loader.times
        XCTAssertEqual(times, [Date(timeIntervalSince1970: 1_200), Date(timeIntervalSince1970: 1_215)])
    }

    func testProviderLimitCannotRaiseTheLocal120RequestMaximum() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(headers: ["X-RateLimit-Limit": "1000", "X-RateLimit-Remaining": "1000", "X-RateLimit-Reset": "60"])])
        for _ in 0..<121 { _ = try await cadence.send(request(), credentials: credentials, loader: loader) }
        XCTAssertEqual(clock.waits, [60])
    }

    func testAPIKeyRotationDoesNotResetTheSameShippersRequestBudget() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock), loader = BetaCadenceLoader()
        let rotated = DirectResearchCredentials(shipperID: credentials.shipperID, apiKey: "rotated-key")
        for number in 0..<120 {
            _ = try await cadence.send(request(), credentials: number.isMultiple(of: 2) ? credentials : rotated, loader: loader)
        }
        XCTAssertTrue(clock.waits.isEmpty)
        _ = try await cadence.send(request(), credentials: rotated, loader: loader)
        XCTAssertEqual(clock.waits, [60])
    }

    func testRetryAfter429And503ShareAnAccountCooldownAndLeaveOtherAccountsAvailable() async throws {
        for status in [429, 503] {
            let clock = BetaCadenceClock(), cadence = coordinator(clock)
            let loader = BetaCadenceLoader([.init(status: status, headers: ["Retry-After": "7"]), .init(), .init()], clock: clock)
            let first = try await cadence.send(request(), credentials: credentials, loader: loader)
            XCTAssertEqual(first.1.statusCode, status, "The caller retains the HTTP failure classification")
            let other = DirectResearchCredentials(shipperID: "another-account", apiKey: "another-key")
            _ = try await cadence.send(request(), credentials: other, loader: loader)
            XCTAssertTrue(clock.waits.isEmpty)
            _ = try await cadence.send(request("/v1/research/meta"), credentials: credentials, loader: loader)
            XCTAssertEqual(clock.waits, [7])
            let times = await loader.times
            XCTAssertEqual(times, [Date(timeIntervalSince1970: 1_200), Date(timeIntervalSince1970: 1_200), Date(timeIntervalSince1970: 1_207)])
        }
    }

    func testRetryAfterHTTPDateIsRelativeToTheInjectedClock() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(status: 429, headers: ["Retry-After": "Thu, 01 Jan 1970 00:20:20 GMT"]), .init()])
        _ = try await cadence.send(request(), credentials: credentials, loader: loader)
        _ = try await cadence.send(request(), credentials: credentials, loader: loader)
        XCTAssertEqual(clock.waits, [20])
    }

    func testIndexIsFreshForADayAndManualRevalidationUsesOnlyItsHTTPETag() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(data: try index("data-one"), headers: ["ETag": "\"http-one\""]),
                                       .init(status: 304, headers: ["ETag": "\"http-two\""]),
                                       .init(data: try index("data-two"), headers: ["ETag": "\"http-three\""])])
        let first = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        XCTAssertEqual(first.dataETag, "data-one")
        clock.set(Date(timeIntervalSince1970: 87_599.5))
        let fresh = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        XCTAssertEqual(fresh.dataETag, "data-one")
        var requests = await loader.requests; XCTAssertEqual(requests.count, 1)
        clock.set(Date(timeIntervalSince1970: 87_600))
        let unchanged = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        XCTAssertEqual(unchanged.dataETag, "data-one")
        XCTAssertEqual(unchanged.checkedAt, Date(timeIntervalSince1970: 87_600))
        clock.set(Date(timeIntervalSince1970: 87_601))
        let changed = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, forceRefresh: true, credentials: credentials, loader: loader)
        XCTAssertEqual(changed.dataETag, "data-two")
        requests = await loader.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"http-one\"")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"http-two\"")
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "If-None-Match") == "data-one" })
    }

    func testMetadataIndexesRemainSeparateByFamilyAndCredentialAccount() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(data: try index("opportunities-hash")), .init(data: try index("research-hash")), .init(data: try index("other-account-hash"))])
        let opportunities = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        let research = try await cadence.setInfo(family: .research, category: 3, group: 1430, credentials: credentials, loader: loader)
        let other = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430,
                                             credentials: .init(shipperID: credentials.shipperID, apiKey: "other-key"), loader: loader)
        XCTAssertEqual(opportunities.dataETag, "opportunities-hash"); XCTAssertEqual(research.dataETag, "research-hash")
        XCTAssertEqual(other.dataETag, "other-account-hash")
        let requests = await loader.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/meta", "/v1/research/meta", "/v1/meta"])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Api-Key"), "other-key")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testValidatedDailyIndexSurvivesRelaunchAndKeepsItsHTTPValidatorSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetaCadenceTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = BetaCadenceClock(), disk = BetaAPIDiskCache(directory: directory)
        let first = BetaAPICadence(now: { clock.now() }, wait: { clock.waitAndAdvance($0) }, disk: disk)
        let loader = BetaCadenceLoader([.init(data: try index("persisted-data-hash"), headers: ["ETag": "\"persisted-http-etag\""])])
        _ = try await first.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        let saved = await disk.entry(for: BetaAPICadence.account(for: credentials) + ":opportunities", kind: .index)
        XCTAssertNotNil(saved, "Only validated index data is saved for the next launch")
        let relaunchedDisk = BetaAPIDiskCache(directory: directory)
        let relaunched = BetaAPICadence(now: { clock.now() }, wait: { clock.waitAndAdvance($0) }, disk: relaunchedDisk)
        let revalidation = BetaCadenceLoader([.init(status: 304)])
        let fresh = try await relaunched.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: revalidation)
        XCTAssertEqual(fresh.dataETag, "persisted-data-hash")
        var requests = await revalidation.requests; XCTAssertTrue(requests.isEmpty)
        let rechecked = try await relaunched.setInfo(family: .opportunities, category: 3, group: 1430, forceRefresh: true, credentials: credentials, loader: revalidation)
        XCTAssertEqual(rechecked.dataETag, "persisted-data-hash")
        requests = await revalidation.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"persisted-http-etag\"")
    }

    func testIndexSelectsOnlyExactNumericCategoryAndSetAndPreservesMissingHash() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(data: try index(nil))])
        let present = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        XCTAssertNil(present.dataETag)
        for selected in [(3, 1431), (1, 1430)] {
            do {
                _ = try await cadence.setInfo(family: .opportunities, category: selected.0, group: selected.1, credentials: credentials, loader: loader)
                XCTFail("A different set or category must not substitute")
            } catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .httpStatus(404)) }
        }
        let requests = await loader.requests; XCTAssertEqual(requests.count, 1)
    }

    func testMalformedMissingAndUnvalidatedIndexResponsesNeverBecomeFresh() async throws {
        let replies: [BetaCadenceLoader.Reply] = [.init(data: Data("{}".utf8)), .init(data: Data("[]".utf8)),
                                                .init(data: Data("{\"categories\":[]}".utf8)), .init(status: 304)]
        for reply in replies {
            let cadence = coordinator(BetaCadenceClock()), loader = BetaCadenceLoader([reply])
            do { _ = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader); XCTFail("Invalid index") }
            catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .invalidResponse) }
        }
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([.init(data: try index()), .init(status: 503)])
        _ = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader)
        clock.set(Date(timeIntervalSince1970: 87_600))
        do { _ = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: loader); XCTFail("Expired index is not fresh fallback") }
        catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .httpStatus(503)) }
    }

    func testConcurrentMetadataLoadsShareOneRequestAndOneCanceledWaiterDoesNotCancelItsPeer() async throws {
        let cadence = coordinator(BetaCadenceClock()), loader = ControlledBetaCadenceLoader()
        let savedCredentials = credentials
        let first = Task { try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: savedCredentials, loader: loader) }
        try await loader.waitForRequests(1)
        let second = Task { try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: savedCredentials, loader: loader) }
        await settle()
        first.cancel()
        await settle()
        await loader.completeFirst(with: try index())
        do { _ = try await first.value; XCTFail("Canceled metadata waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result.dataETag, "data-hash")
        let count = await loader.requests.count; XCTAssertEqual(count, 1)
    }

    func testCancellationBeforeSendConsumesNoBudgetAndSentCancellationDoesNotRefundIt() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let savedCredentials = credentials, selectedRequest = request()
        let initialLoader = BetaCadenceLoader()
        let alreadyCanceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cadence.send(selectedRequest, credentials: savedCredentials, loader: initialLoader)
        }
        do { _ = try await alreadyCanceled.value; XCTFail("Canceled before request") }
        catch { XCTAssertTrue(error is CancellationError) }
        var requests = await initialLoader.requests; XCTAssertTrue(requests.isEmpty)
        let controlled = ControlledBetaCadenceLoader()
        let sent = Task { try await cadence.send(selectedRequest, credentials: savedCredentials, loader: controlled) }
        try await controlled.waitForRequests(1); sent.cancel()
        await controlled.completeFirst(with: Data())
        do { _ = try await sent.value; XCTFail("Canceled after request") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<119 { _ = try await cadence.send(request(), credentials: credentials, loader: initialLoader) }
        XCTAssertTrue(clock.waits.isEmpty, "The canceled-before-send operation consumed no slot")
        _ = try await cadence.send(request(), credentials: credentials, loader: initialLoader)
        XCTAssertEqual(clock.waits, [60], "The operation canceled after send still consumes its slot")
        requests = await initialLoader.requests; XCTAssertEqual(requests.count, 120)
    }

    func testCancellationWhileWaitingForBudgetNeverDispatchesAnExtraRequest() async throws {
        let clock = BetaCadenceClock()
        let cadence = BetaAPICadence(now: { clock.now() }, wait: { seconds in
            clock.recordWait(seconds)
            try await Task.sleep(for: .seconds(seconds))
        })
        let loader = BetaCadenceLoader()
        for _ in 0..<120 { _ = try await cadence.send(request(), credentials: credentials, loader: loader) }
        let selected = request(), savedCredentials = credentials
        let waiting = Task { try await cadence.send(selected, credentials: savedCredentials, loader: loader) }
        for _ in 0..<200 {
            if !clock.waits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(clock.waits, [60])
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Canceled budget wait") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await loader.requests; XCTAssertEqual(requests.count, 120)
    }

    func testCanceledLastIndexWaiterDoesNotAllowItsLateReplyToSeedTheIndexCache() async throws {
        let cadence = coordinator(BetaCadenceClock()), loader = ControlledBetaCadenceLoader()
        let savedCredentials = credentials
        let pending = Task { try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: savedCredentials, loader: loader) }
        try await loader.waitForRequests(1); pending.cancel(); await settle()
        await loader.completeFirst(with: try index("late-hash"))
        do { _ = try await pending.value; XCTFail("Canceled index lookup") }
        catch { XCTAssertTrue(error is CancellationError) }
        let replacement = BetaCadenceLoader([.init(data: try index("new-hash"))])
        let result = try await cadence.setInfo(family: .opportunities, category: 3, group: 1430, credentials: credentials, loader: replacement)
        XCTAssertEqual(result.dataETag, "new-hash")
        let requests = await replacement.requests; XCTAssertEqual(requests.count, 1)
    }

    func testUnsafeOriginsQueriesPathsAndRedirectResponsesAreRejected() async throws {
        let cadence = coordinator(BetaCadenceClock()), loader = BetaCadenceLoader()
        for text in ["http://beta.tcgtracking.com/v1/meta", "https://other.example/v1/meta", "https://beta.tcgtracking.com/v1/meta?key=secret",
                     "https://user:secret@beta.tcgtracking.com/v1/meta", "https://beta.tcgtracking.com/v1/meta#fragment",
                     "https://beta.tcgtracking.com/v1/3/sets/0", "https://beta.tcgtracking.com/not-an-api"] {
            do { _ = try await cadence.send(URLRequest(url: URL(string: text)!), credentials: credentials, loader: loader); XCTFail("Unsafe Beta URL") }
            catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .invalidRequest) }
        }
        let requests = await loader.requests; XCTAssertTrue(requests.isEmpty)
        do { _ = try await cadence.send(request(method: "POST"), credentials: credentials, loader: loader); XCTFail("Unsupported method") }
        catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .invalidRequest) }
        let redirected = BetaCadenceLoader([.init(url: URL(string: "https://other.example/v1/meta"))])
        do { _ = try await cadence.send(request(), credentials: credentials, loader: redirected); XCTFail("Untrusted redirect") }
        catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .invalidResponse) }
    }

    func testOversizedAndRawTransportFailuresStayTypedAndDoNotRevealProviderMessages() async throws {
        let cadence = coordinator(BetaCadenceClock())
        let tooLarge = BetaCadenceLoader([.init(data: Data(repeating: 32, count: 8 * 1_024 * 1_024 + 1))])
        do { _ = try await cadence.send(request(), credentials: credentials, loader: tooLarge); XCTFail("Bounded response") }
        catch { XCTAssertEqual(error as? BetaAPICadenceFailure, .responseTooLarge) }
        do { _ = try await cadence.send(request(), credentials: credentials, loader: FailingBetaCadenceLoader()); XCTFail("Transport failure") }
        catch {
            XCTAssertEqual(error as? BetaAPICadenceFailure, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("private-provider-message"))
        }
    }

    func testOpportunitiesIndexRefreshSkipsUnchangedShardAndFetchesChangedHashImmediately() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock), cache = OpportunitiesSetCache(disk: nil)
        let loader = BetaCadenceLoader([
            .init(data: try index("data-a"), headers: ["ETag": "\"index-http-a\""]),
            .init(data: try opportunityShard("data-a", price: 7), headers: ["ETag": "\"shard-http-a\""]),
            .init(status: 304, headers: ["ETag": "\"index-http-unchanged\""]),
            .init(data: try index("data-b"), headers: ["ETag": "\"index-http-b\""]),
            .init(data: try opportunityShard("data-b", price: 9), headers: ["ETag": "\"shard-http-b\""])
        ])
        let client = DirectOpportunitiesClient(credentials: credentials, resolver: BetaCadenceResolver(), loader: loader,
            cache: cache, cadence: cadence, now: { clock.now() })
        let selected = opportunityCard()
        let initial = try await client.opportunities(for: selected, forceRefresh: false)
        XCTAssertEqual(initial.sku.pricing?.marketSKU, 7)
        _ = try await client.opportunities(for: selected, forceRefresh: false)
        var requests = await loader.requests; XCTAssertEqual(requests.count, 2, "Fresh index and shard perform no HTTP")
        _ = try await client.opportunities(for: selected, forceRefresh: true)
        requests = await loader.requests; XCTAssertEqual(requests.count, 3, "A 304 index retains its data hash and skips the shard")
        let changed = try await client.opportunities(for: selected, forceRefresh: true)
        XCTAssertEqual(changed.sku.pricing?.marketSKU, 9, "A changed data hash bypasses the daily shard age")
        requests = await loader.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/meta", "/v1/3/sets/1430", "/v1/meta", "/v1/meta", "/v1/3/sets/1430"])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-a\"")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"index-http-unchanged\"")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "If-None-Match"), "\"shard-http-a\"")
        XCTAssertFalse(requests.contains { ["data-a", "data-b"].contains($0.value(forHTTPHeaderField: "If-None-Match") ?? "") })
    }

    func testOpportunitiesRelaunchReusesDailyDiskSnapshotsAndUnchangedDailyIndexSkipsExpiredShard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BetaOpportunitiesTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = BetaCadenceClock(), firstDisk = BetaAPIDiskCache(directory: directory)
        let firstCadence = BetaAPICadence(now: { clock.now() }, wait: { clock.waitAndAdvance($0) }, disk: firstDisk)
        let firstLoader = BetaCadenceLoader([
            .init(data: try index("same-data"), headers: ["ETag": "\"index-http\""]),
            .init(data: try opportunityShard("same-data", price: 7), headers: ["ETag": "\"shard-http\""])
        ])
        let first = DirectOpportunitiesClient(credentials: credentials, resolver: BetaCadenceResolver(), loader: firstLoader,
            cache: OpportunitiesSetCache(disk: firstDisk), cadence: firstCadence, now: { clock.now() })
        _ = try await first.opportunities(for: opportunityCard(), forceRefresh: false)
        let relaunchedDisk = BetaAPIDiskCache(directory: directory)
        let relaunchedCadence = BetaAPICadence(now: { clock.now() }, wait: { clock.waitAndAdvance($0) }, disk: relaunchedDisk)
        let relaunchedLoader = BetaCadenceLoader([.init(data: try index("same-data"), headers: ["ETag": "\"next-index-http\""])])
        let relaunched = DirectOpportunitiesClient(credentials: credentials, resolver: BetaCadenceResolver(), loader: relaunchedLoader,
            cache: OpportunitiesSetCache(disk: relaunchedDisk), cadence: relaunchedCadence, now: { clock.now() })
        let saved = try await relaunched.opportunities(for: opportunityCard(), forceRefresh: false)
        XCTAssertEqual(saved.sku.pricing?.marketSKU, 7)
        var requests = await relaunchedLoader.requests; XCTAssertTrue(requests.isEmpty, "Daily metadata and shard survive process restart")
        clock.set(Date(timeIntervalSince1970: 87_601))
        let checked = try await relaunched.opportunities(for: opportunityCard(), forceRefresh: false)
        XCTAssertEqual(checked.sku.pricing?.marketSKU, 7)
        requests = await relaunchedLoader.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/meta"], "An unchanged index hash validates reuse of the older shard")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"index-http\"")
    }

    func testOpportunitiesMissingIndexCoverageIsExplicitAndNeverRequestsResearch() async throws {
        for reply in [BetaCadenceLoader.Reply(status: 404), .init(data: try index("other-set", group: "1431"))] {
            let clock = BetaCadenceClock(), loader = BetaCadenceLoader([reply])
            let client = DirectOpportunitiesClient(credentials: credentials, resolver: BetaCadenceResolver(), loader: loader,
                cache: OpportunitiesSetCache(disk: nil), cadence: coordinator(clock), now: { clock.now() })
            do { _ = try await client.opportunities(for: opportunityCard(), forceRefresh: false); XCTFail("Exact index coverage is required") }
            catch { XCTAssertEqual(error as? OpportunitiesFailure, .notCovered) }
            let requests = await loader.requests
            XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/meta"])
        }
    }

    func testChangedIndexCannotAcceptAnOldShardThroughHTTP304() async throws {
        let clock = BetaCadenceClock(), cadence = coordinator(clock)
        let loader = BetaCadenceLoader([
            .init(data: try index("data-a")), .init(data: try opportunityShard("data-a", price: 7), headers: ["ETag": "\"shard-a\""]),
            .init(data: try index("data-b")), .init(status: 304)
        ])
        let client = DirectOpportunitiesClient(credentials: credentials, resolver: BetaCadenceResolver(), loader: loader,
            cache: OpportunitiesSetCache(), cadence: cadence, now: { clock.now() })
        _ = try await client.opportunities(for: opportunityCard(), forceRefresh: false)
        do { _ = try await client.opportunities(for: opportunityCard(), forceRefresh: true); XCTFail("Old body cannot satisfy changed index") }
        catch { XCTAssertEqual(error as? OpportunitiesFailure, .invalidResponse) }
    }

    private func opportunityCard() -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", printing: "Holofoil"),
                      name: "Fixture", set: "Display set", number: "42", marketPrice: nil,
                      confidence: 99, printings: ["Holofoil"])
    }
    private func opportunityShard(_ hash: String, price: Int) throws -> Data {
        let body: [String: Any] = [
            "meta": ["category_id": 3, "group_id": 1430, "etag": hash],
            "products": ["42": ["product_id": 42, "name": "Fixture", "skus": ["101": [
                "sku_id": 101, "condition_id": 1, "condition": "Near Mint", "finish": "Holofoil", "language": "English",
                "pricing": ["market_sku": price]
            ]]]]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

private final class BetaCadenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_200)
    private var recordedWaits: [TimeInterval] = []
    var waits: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recordedWaits }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; current = value }
    func recordWait(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; recordedWaits.append(seconds) }
    func waitAndAdvance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        recordedWaits.append(seconds); current = current.addingTimeInterval(seconds)
    }
}

private actor BetaCadenceLoader: ResearchHTTPDataLoading {
    struct Reply: Sendable { var status = 200; var data = Data(); var headers: [String: String] = [:]; var url: URL? }
    private var replies: [Reply]
    private let clock: BetaCadenceClock?
    private(set) var requests: [URLRequest] = []
    private(set) var times: [Date] = []
    init(_ replies: [Reply] = [], clock: BetaCadenceClock? = nil) { self.replies = replies; self.clock = clock }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request); times.append(clock?.now() ?? Date())
        let reply = replies.isEmpty ? Reply() : replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}

private actor ControlledBetaCadenceLoader: ResearchHTTPDataLoading {
    private struct Pending { let request: URLRequest; let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error> }
    private var pending: [Pending] = []
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending.append(Pending(request: request, continuation: $0)) }
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func completeFirst(with data: Data) {
        guard !pending.isEmpty else { return }
        let selected = pending.removeFirst()
        selected.continuation.resume(returning: (data, HTTPURLResponse(url: selected.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

private struct FailingBetaCadenceLoader: ResearchHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw NSError(domain: "private-provider-message", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-provider-message secret-key"])
    }
}

private struct BetaCadenceResolver: OpenAPISetResolving {
    func setID(for card: CardCandidate) async throws -> Int? { 1430 }
}
