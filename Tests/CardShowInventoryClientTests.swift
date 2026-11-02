import XCTest
@testable import CardShowScanner

@MainActor final class CardShowInventoryClientTests: XCTestCase {
    func testDiscoversExactLocationAndKeepsDistinctRowsQuantitiesAndExactCardFields() async throws {
        let loader = InventoryImportLoader([.init(try locations()), .init(try page([
            row(1, quantity: 2, price: "0"), row(2, quantity: 3, price: NSNull())
        ]))])
        let result = try await client(loader).fetch(expectedLocationID: nil)
        XCTAssertEqual(result.location, .init(id: 42, name: "Card Show"))
        XCTAssertEqual(result.rows.map(\.inventoryID), [1, 2])
        XCTAssertEqual(result.rows.map(\.quantity), [2, 3])
        XCTAssertEqual(result.rows.first?.card.identity, .init(game: "Pokémon", productID: "p:12", skuID: "100",
            printing: "Holofoil", language: "English", condition: "Lightly Played"))
        XCTAssertEqual(result.rows.first?.card.marketPrice, 0)
        XCTAssertNil(result.rows.last?.card.marketPrice)
        XCTAssertNil(result.rows.first?.card.marketPriceMetadata, "Website inventory is not a freshly fetched Open API quote")
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 2)
        let parameters = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(parameters.first { $0.name == "location_ids" }?.value, "42")
        XCTAssertNil(parameters.first { $0.name == "location_id" })
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }

    func testCompletePaginationAndDistinctInventoryIDsForSameSKU() async throws {
        var first = (1...500).map { row($0) }
        first[14] = row(15, quantity: 4, price: ["unavailable": true])
        let last = [row(501, price: "12not-money")]
        let loader = InventoryImportLoader([.init(try locations()), .init(try page(first, total: 501, pages: 2)),
            .init(try page(last, number: 2, total: 501, pages: 2))])
        let result = try await client(loader).fetch(expectedLocationID: 42)
        XCTAssertEqual(result.rows.count, 501)
        XCTAssertEqual(Set(result.rows.map(\.inventoryID)).count, 501)
        XCTAssertEqual(Set(result.rows.map { $0.card.identity.skuID }).count, 1)
        XCTAssertEqual(result.rows.map(\.inventoryID), Array(1...501))
        XCTAssertEqual(result.rows.reduce(0) { $0 + $1.quantity }, 504)
        XCTAssertEqual(result.rows[14].quantity, 4)
        XCTAssertNil(result.rows[14].card.marketPrice)
        XCTAssertNil(result.rows[500].card.marketPrice)
        XCTAssertEqual(result.rows[13].card.marketPrice, Decimal(string: "3.50"))
    }

    func testLiteralJSONNumericAndStringQuotesImportWithoutLosingDecimalPrecision() async throws {
        let literals = ["0", #""0""#, "6.77", #""6.77""#, "8.28", #""8.28""#, "8.6",
            "0.1234567890123456789012345678", "1e-9", "6.77e-7", "677e-2", "8.600000000000001", "3.50", "6.77", "8.28"]
        let expected = ["0", "0", "6.77", "6.77", "8.28", "8.28", "8.6", "0.1234567890123456789012345678",
            "0.000000001", "0.000000677", "6.77", "8.600000000000001", "3.50", "6.77", "8.28"]
        let body = try pageWithLiteralPrices(literals)
        let loader = InventoryImportLoader([.init(try locations()), .init(body)])
        let result = try await client(loader).fetch(expectedLocationID: 42)
        XCTAssertEqual(result.rows.map(\.inventoryID), Array(1...literals.count))
        XCTAssertEqual(result.rows.map { $0.card.marketPrice }, expected.map { Decimal(string: $0) })
        let decoded = try CardShowInventoryDecoder.page(body, location: .init(id: 42, name: "Card Show"), requestedPage: 1)
        XCTAssertEqual(decoded.marketPriceDiagnosticFields,
            ["priced_records": "15", "unpriced_records": "0", "invalid_price_records": "0"])
    }

    func testMissingBlankAndMalformedOptionalQuotesKeepEveryRowWithUnavailablePrices() async throws {
        var missing = row(6)
        missing.removeValue(forKey: "market_price")
        var rows = [row(1, price: "0"), row(2, price: 0), row(3, price: NSNull()), row(4, price: ""),
                    row(5, price: " \t\n "), missing]
        let malformed: [Any] = ["12not-money", true, false, ["amount": "6.77"], [], -1, "-0.01", "NaN",
            "Infinity", "-Infinity", "6.77\njunk", "6.77.1", "6.77usd", "+6.77", "6,77", "1e2",
            "0.000000001", "1000000000000", String(repeating: "9", count: 129)]
        rows += malformed.enumerated().map { row($0.offset + 7, price: $0.element) }
        let body = try page(rows)
        let loader = InventoryImportLoader([.init(try locations()), .init(body)])
        let result = try await client(loader).fetch(expectedLocationID: 42)
        XCTAssertEqual(result.rows.map(\.inventoryID), Array(1...rows.count))
        XCTAssertEqual(result.rows[0].card.marketPrice, 0)
        XCTAssertEqual(result.rows[1].card.marketPrice, 0)
        XCTAssertTrue(result.rows.dropFirst(2).allSatisfy { $0.card.marketPrice == nil },
            "Unavailable market quotes must not become zero or use my_price/low_price")
        let decoded = try CardShowInventoryDecoder.page(body, location: .init(id: 42, name: "Card Show"), requestedPage: 1)
        XCTAssertEqual(decoded.marketPriceDiagnosticFields, ["priced_records": "2", "unpriced_records": String(rows.count - 2),
            "invalid_price_records": String(malformed.count)])
    }

    func testOutOfRangeNumericQuotesStayUnavailableWithoutBecomingZero() async throws {
        let body = try pageWithLiteralPrices(["1e-129", "1e127", "-6.77", "1000000000000"])
        let loader = InventoryImportLoader([.init(try locations()), .init(body)])
        let result = try await client(loader).fetch(expectedLocationID: 42)
        XCTAssertEqual(result.rows.count, 4)
        XCTAssertTrue(result.rows.allSatisfy { $0.card.marketPrice == nil })
        let decoded = try CardShowInventoryDecoder.page(body, location: .init(id: 42, name: "Card Show"), requestedPage: 1)
        XCTAssertEqual(decoded.marketPriceDiagnosticFields,
            ["priced_records": "0", "unpriced_records": "4", "invalid_price_records": "4"])
    }

    func testMissingAmbiguousAndChangedLocationsDoNotRequestStock() async throws {
        let bodies: [(Data, CardShowInventoryFailure)] = [
            (try locations(name: "Card Show Need To Price"), .locationNotFound),
            (try locations(extra: [["location_id": 43, "name": "Card Show", "is_active": 1]]), .ambiguousLocation)
        ]
        for (body, failure) in bodies {
            let loader = InventoryImportLoader([.init(body)])
            await assertFailure(failure) { try await self.client(loader).fetch(expectedLocationID: nil) }
            let calls = await loader.requests; XCTAssertEqual(calls.count, 1)
        }
        let loader = InventoryImportLoader([.init(try locations(id: 99))])
        await assertFailure(.locationChanged) { try await self.client(loader).fetch(expectedLocationID: 42) }
        let calls = await loader.requests; XCTAssertEqual(calls.count, 1)
    }

    func testRejectsOtherLocationsAndMalformedRowsInsteadOfPartiallyImporting() async throws {
        let changes: [[String: Any]] = [
            ["inventory_id": NSNull()], ["location_id": 43], ["quantity": -1], ["quantity": true],
            ["quantity": 1.5], ["quantity": "1.0"], ["quantity": 1_000_001], ["product_id": 0], ["sku_id": NSNull()],
            ["condition_name": NSNull()], ["variant_name": ""], ["inventory_type": "custom"]
        ]
        for change in changes {
            let invalid = row(2).merging(change) { _, new in new }
            let loader = InventoryImportLoader([.init(try locations()), .init(try page([row(1), invalid]))])
            await assertFailure(.invalidResponse) { try await self.client(loader).fetch(expectedLocationID: 42) }
        }
    }

    func testKnownEmptyInventoryAndZeroQuantityAreValidCompleteSnapshots() async throws {
        let empty = InventoryImportLoader([.init(try locations()), .init(try page([]))])
        let snapshot = try await client(empty).fetch(expectedLocationID: 42)
        XCTAssertTrue(snapshot.rows.isEmpty)
        let noPages = InventoryImportLoader([.init(try locations()), .init(try page([], pages: 0))])
        let noPagesResult = try await client(noPages).fetch(expectedLocationID: 42)
        XCTAssertTrue(noPagesResult.rows.isEmpty)
        let zero = InventoryImportLoader([.init(try locations()), .init(try page([row(1, quantity: 0)]))])
        let result = try await client(zero).fetch(expectedLocationID: 42)
        XCTAssertEqual(result.rows.first?.quantity, 0)
    }

    func testRepeatedRowsChangingTotalsAndTruncatedPagesAreRejected() async throws {
        let first = (1...500).map { row($0) }
        for last in [try page([row(1)], number: 2, total: 501, pages: 2),
                     try page([row(501), row(502)], number: 2, total: 502, pages: 2)] {
            let loader = InventoryImportLoader([.init(try locations()), .init(try page(first, total: 501, pages: 2)), .init(last)])
            await assertFailure(.invalidResponse) { try await self.client(loader).fetch(expectedLocationID: 42) }
        }
        for body in [try page([row(1), row(1)]), try page([row(1)], total: 2),
                     try page([], total: 10_001, pages: 21)] {
            let loader = InventoryImportLoader([.init(try locations()), .init(body)])
            do { _ = try await client(loader).fetch(expectedLocationID: 42); XCTFail("A partial snapshot cannot replace saved inventory") }
            catch { XCTAssertTrue(error is CardShowInventoryFailure) }
        }
    }

    func testAuthenticationHTMLRedirectsRateLimitsAndWrongResponseURLAreRejected() async throws {
        let cases: [(InventoryImportLoader.Reply, CardShowInventoryFailure)] = [
            (.init(Data(), status: 401), .signInRequired), (.init(Data(), status: 403), .signInRequired),
            (.init(Data(), status: 302), .signInRequired), (.init(Data(), status: 429), .rateLimited),
            (.init(Data("<html>Sign in</html>".utf8), mime: "text/html"), .signInRequired),
            (.init(Data("{\"success\":false,\"error\":\"authentication required\"}".utf8)), .signInRequired),
            (.init(try locations(), redirected: URL(string: "https://example.com/inventory")!), .invalidResponse)
        ]
        for (reply, failure) in cases {
            await assertFailure(failure) { try await self.client(InventoryImportLoader([reply])).fetch(expectedLocationID: nil) }
        }
    }

    func testMissingWebsiteSessionDoesNotMakeAnAnonymousInventoryRequest() async throws {
        let loader = InventoryImportLoader([])
        let provider = CardShowInventoryWebsiteClient(cookies: { [] }, makeLoader: { _ in loader }, isActive: { true })
        await assertFailure(.signInRequired) { try await provider.fetch(expectedLocationID: nil) }
        let calls = await loader.requests; XCTAssertTrue(calls.isEmpty)
    }

    func testInactiveClientDoesNotReadCookiesOrLoadAndCancelRejectsLateReply() async throws {
        let empty = InventoryImportLoader([])
        let inactive = CardShowInventoryWebsiteClient(cookies: { XCTFail("Inactive app must not read cookies"); return [] },
                                                      makeLoader: { _ in empty }, isActive: { false })
        do { _ = try await inactive.fetch(expectedLocationID: nil); XCTFail("Inactive app cannot fetch") }
        catch { XCTAssertTrue(error is CancellationError) }
        let held = HeldInventoryImportLoader()
        let provider = client(held)
        let fetch = Task { try await provider.fetch(expectedLocationID: nil) }
        try await held.waitForRequest()
        provider.cancel()
        await held.finish(try locations())
        do { _ = try await fetch.value; XCTFail("A retired request cannot publish a snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransportOnlyAllowsFixedReadEndpointsAndScopesCookiesToAccountHost() throws {
        XCTAssertTrue(NativeCardShowInventoryHTTPDataLoader.allowed(CardShowInventoryWebsiteClient.locationsURL))
        XCTAssertTrue(NativeCardShowInventoryHTTPDataLoader.allowed(CardShowInventoryWebsiteClient.stockURL(locationID: 42, page: 1)))
        for raw in ["https://example.com/dash/controllers/ajax/inventory-stock.php?action=list",
                    "http://tcgtracking.com/dash/controllers/ajax/inventory-locations.php?action=list",
                    "https://tcgtracking.com/dash/controllers/ajax/inventory-locations.php?action=delete",
                    "https://tcgtracking.com/dash/controllers/ajax/inventory-locations.php?action=list&action=delete",
                    "https://tcgtracking.com/dash/controllers/ajax/inventory-stock.php?action=list&location_id=42&page=1&limit=500&sort=live_desc"] {
            XCTAssertFalse(NativeCardShowInventoryHTTPDataLoader.allowed(try XCTUnwrap(URL(string: raw))))
        }
        let now = Date()
        let cookies = [cookie("tcgtracking.com"), cookie(".tcgtracking.com"), cookie("evil-tcgtracking.com"),
                       cookie("tcgtracking.com.evil.example"), cookie("tcgtracking.com", expires: now.addingTimeInterval(-1))]
        XCTAssertEqual(CardShowInventoryWebsiteClient.accountCookies(cookies, now: now).count, 2)
    }

    func testRowRejectionIdentifiesOnlyTheFieldPageAndPositionWithoutLoggingSourceValues() async throws {
        let capture = try diagnosticCapture()
        defer { capture.cleanup() }
        var invalid = row(2)
        invalid["sku_id"] = NSNull()
        invalid["product_name"] = "PRIVATE_CARD_AND_TOKEN"
        invalid["notes"] = "PRIVATE_ACCOUNT_COOKIE"
        let loader = InventoryImportLoader([.init(try locations()), .init(try page([row(1), invalid]))])
        await assertFailure(.invalidResponse) { try await self.client(loader, log: capture.log).fetch(expectedLocationID: 42) }
        let (text, events) = try capture.events()
        let event = try XCTUnwrap(events.first { $0["event"] as? String == "card_show_inventory.rejected" })
        let fields = try XCTUnwrap(event["fields"] as? [String: String])
        XCTAssertEqual(fields["phase"], "stock"); XCTAssertEqual(fields["stage"], "row")
        XCTAssertEqual(fields["reason"], "sku_id_invalid"); XCTAssertEqual(fields["page"], "1")
        XCTAssertEqual(fields["record_index"], "1")
        XCTAssertFalse(events.contains { $0["event"] as? String == "card_show_inventory.page_decoded" })
        XCTAssertFalse(events.contains { $0["event"] as? String == "card_show_inventory.snapshot_decoded" })
        XCTAssertFalse(text.contains("PRIVATE_")); XCTAssertFalse(text.contains("fixture-only"))
        XCTAssertFalse(text.contains("Synthetic inventory card")); XCTAssertFalse(text.contains("https://tcgtracking.com"))
    }

    func testPaginationRejectionReportsTheLimitCheckpointInsteadOfGenericInvalidResponse() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: page([row(1)])) as? [String: Any])
        let changed = object.merging(["limit": 100]) { _, new in new }
        XCTAssertThrowsError(try CardShowInventoryDecoder.page(JSONSerialization.data(withJSONObject: changed),
            location: .init(id: 42, name: "Card Show"), requestedPage: 1)) { error in
            let rejection = error as? CardShowInventoryValidationFailure
            XCTAssertEqual(rejection?.failure, .invalidResponse)
            XCTAssertEqual(rejection?.stage, .pagination); XCTAssertEqual(rejection?.reason, .limit)
            XCTAssertEqual(rejection?.page, 1); XCTAssertNil(rejection?.recordIndex)
        }
    }

    func testHTMLAndHTTPAuthenticationHaveDistinctCheckpointsAndSameSignInBehavior() async throws {
        for (reply, reason) in [(InventoryImportLoader.Reply(Data("PRIVATE_LOGIN_BODY".utf8), mime: "text/html"), "content_type"),
                                (.init(Data("PRIVATE_AUTH_BODY".utf8), status: 401), "http_authentication")] {
            let capture = try diagnosticCapture()
            defer { capture.cleanup() }
            await assertFailure(.signInRequired) {
                try await self.client(InventoryImportLoader([reply]), log: capture.log).fetch(expectedLocationID: nil)
            }
            let (text, events) = try capture.events()
            let event = try XCTUnwrap(events.first { $0["event"] as? String == "card_show_inventory.rejected" })
            let fields = try XCTUnwrap(event["fields"] as? [String: String])
            XCTAssertEqual(fields["stage"], "response"); XCTAssertEqual(fields["reason"], reason)
            XCTAssertFalse(text.contains("PRIVATE_")); XCTAssertFalse(text.contains("fixture-only"))
        }
    }

    func testSuccessfulDecodeLogsCountsBeforePersistenceWithoutSourceContents() async throws {
        let capture = try diagnosticCapture()
        defer { capture.cleanup() }
        let loader = InventoryImportLoader([.init(try locations()), .init(try page([row(1), row(2)]))])
        _ = try await client(loader, log: capture.log).fetch(expectedLocationID: 42)
        let (text, events) = try capture.events()
        let event = try XCTUnwrap(events.first { $0["event"] as? String == "card_show_inventory.page_decoded" })
        let fields = try XCTUnwrap(event["fields"] as? [String: String])
        XCTAssertEqual(fields["page"], "1"); XCTAssertEqual(fields["records"], "2"); XCTAssertEqual(fields["total"], "2")
        XCTAssertEqual(fields["priced_records"], "2"); XCTAssertEqual(fields["unpriced_records"], "0")
        XCTAssertEqual(fields["invalid_price_records"], "0")
        XCTAssertTrue(events.contains { $0["event"] as? String == "card_show_inventory.snapshot_decoded" })
        XCTAssertFalse(text.contains("Synthetic inventory card")); XCTAssertFalse(text.contains("Synthetic set"))
    }

    private func diagnosticCapture() throws -> InventoryDiagnosticCapture {
        let name = "CardShowInventoryClientTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: "diagnosticsEnabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        return InventoryDiagnosticCapture(log: DiagnosticLog(directory: directory, defaults: defaults), directory: directory,
                                          defaults: defaults, suite: name)
    }

    private func client(_ loader: any CardShowInventoryHTTPDataLoading, log: DiagnosticLog? = nil) -> CardShowInventoryWebsiteClient {
        let session = cookie("tcgtracking.com")
        return .init(cookies: { [session] }, makeLoader: { _ in loader }, isActive: { true }, log: log)
    }
    private func cookie(_ domain: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "SyntheticSession", .value: "fixture-only", .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    private func locations(id: Int = 42, name: String = "Card Show", extra: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": true, "locations":
            [["location_id": id, "name": name, "is_active": 1],
             ["location_id": 44, "name": "Card Show Need To Price", "is_active": 1]] + extra])
    }
    private func row(_ id: Int, quantity: Int = 1, price: Any = "3.50") -> [String: Any] {
        ["inventory_id": id, "location_id": 42, "quantity": quantity, "product_id": 12, "sku_id": 100,
         "product_name": "Synthetic inventory card", "set_name": "Synthetic set", "game_name": "Pokemon",
         "variant_name": "Holofoil", "condition_name": "Lightly Played", "language_name": "English",
         "ext_number": "044", "market_price": price, "my_price": 999, "low_price": 888, "inventory_type": "stock"]
    }
    private func page(_ rows: [[String: Any]], number: Int = 1, total: Int? = nil, pages: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": true, "items": rows, "total": total ?? rows.count,
            "stock_total": total ?? rows.count, "custom_total": 0, "inventory_type": "stock", "page": number, "pages": pages, "limit": 500])
    }
    private func pageWithLiteralPrices(_ literals: [String]) throws -> Data {
        let rows = literals.indices.map { row($0 + 1, price: "SYNTHETIC_PRICE_LITERAL_\($0)") }
        var json = String(decoding: try page(rows), as: UTF8.self)
        for (index, literal) in literals.enumerated() {
            json = json.replacingOccurrences(of: "\"SYNTHETIC_PRICE_LITERAL_\(index)\"", with: literal)
        }
        return Data(json.utf8)
    }
    private func assertFailure(_ failure: CardShowInventoryFailure, operation: () async throws -> CardShowInventorySnapshot,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(failure)", file: file, line: line) }
        catch { XCTAssertEqual(error as? CardShowInventoryFailure, failure, file: file, line: line) }
    }
}

@MainActor private struct InventoryDiagnosticCapture {
    let log: DiagnosticLog
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    func events() throws -> (String, [[String: Any]]) {
        let exported = try log.export()
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let text = try String(contentsOf: exported, encoding: .utf8)
        let events = try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        return (text, events)
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor InventoryImportLoader: CardShowInventoryHTTPDataLoading {
    struct Reply: Sendable {
        let data: Data
        let status: Int
        let mime: String
        let redirected: URL?
        init(_ data: Data, status: Int = 200, mime: String = "application/json", redirected: URL? = nil) {
            self.data = data; self.status = status; self.mime = mime; self.redirected = redirected
        }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty, let url = request.url else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.redirected ?? url, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mime])!)
    }
}

private actor HeldInventoryImportLoader: CardShowInventoryHTTPDataLoading {
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var request: URLRequest?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForRequest() async throws {
        for _ in 0..<200 {
            if pending != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func finish(_ data: Data) {
        guard let request, let url = request.url else { return }
        let current = pending; pending = nil
        current?.resume(returning: (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!))
    }
}
