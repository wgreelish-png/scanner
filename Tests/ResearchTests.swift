import XCTest
@testable import CardShowScanner

@MainActor final class ResearchTests: XCTestCase {
    private func card(_ ref: String = "p:42", printing: String = "Holofoil", language: String = "English", game: String = "Pokémon") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: game, productID: ref, printing: printing, language: language),
                      name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 7,
                      confidence: 99, printings: ["Holofoil", "Normal"])
    }
    private func fixture(productID: Int = 42, categoryID: Int = 3, groupID: Int = 1430,
                         grades: [[String: Any]]? = nil, extraVariants: [String: Any] = [:]) throws -> Data {
        let defaultGrades: [[String: Any]] = [
            ["grader": "RAW", "grade": "Raw", "guide_value": 1, "market_value": NSNull(), "pop": NSNull(), "sales": 0],
            ["grader": "PSA", "grade": "10", "guide_value": "100.25", "market_value": 95, "pop": 0, "sales": 12, "confidence": 4,
             "last_sold_at": "2026-10-20", "synced_on": "2026-10-21", "daily_history": [
                "updated_at": "2026-10-21T12:00:00Z", "stats": [
                    "last_sale": ["price": 0, "date": "2026-10-20"], "change": ["month": -12.5],
                    "month": ["sales": 3, "avg": 80.5, "low": 0, "high": 100], "year": ["sales": 12, "avg": NSNull()]],
                "series": [["2026-10-20", 0, 0], ["2026-10-18", 2, 80.5]]]],
            ["grader": "PSA", "grade": "9.5", "guide_value": 50],
            ["grader": "BGS", "grade": "10 Black Label", "guide_value": 200],
            ["grader": "CGC", "grade": "10 Pristine", "guide_value": 120]
        ]
        var variants = extraVariants
        variants["EN:Holofoil"] = ["language": "EN", "finish": "Holofoil", "updated_at": "2026-10-21T12:00:00Z", "grades": grades ?? defaultGrades]
        return try JSONSerialization.data(withJSONObject: [
            "meta": ["schema_version": "2.0-testing", "status": "in_testing", "category_id": categoryID, "group_id": groupID,
                     "set_name": "Fixture set", "generated_at": "2026-10-21T12:00:00Z"],
            "product": ["product_id": productID, "name": "Fixture card", "ext_number": "42", "catalog_market_price": 7,
                        "images": ["front_400": "https://cdn.tcgtracking.com/product/42_400w.jpg"], "variants": variants]
        ])
    }
    private func details(_ data: Data? = nil) throws -> ResearchProductDetails {
        try ResearchProductDetails.decode(data ?? fixture(), expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }

    func testDocumentedResearchFieldsKeepEstimatesSalesAndPopulationSeparate() async throws {
        let response = try details(), grade = try XCTUnwrap(response.product.variants["EN:Holofoil"]?.grades.first { $0.grader == "PSA" && $0.grade == "10" })
        XCTAssertEqual(response.meta.status, "in_testing")
        XCTAssertEqual(response.meta.generatedAt, "2026-10-21T12:00:00Z")
        XCTAssertEqual(grade.guideValue, Decimal(string: "100.25")); XCTAssertEqual(grade.marketValue, 95)
        XCTAssertEqual(grade.population, 0); XCTAssertEqual(grade.sales, 12); XCTAssertEqual(grade.confidence, 4)
        XCTAssertEqual(grade.dailyHistory?.stats?.month?.sales, 3)
        XCTAssertEqual(grade.dailyHistory?.stats?.month?.average, Decimal(string: "80.5"))
        XCTAssertEqual(grade.dailyHistory?.stats?.lastSale?.price, 0)
        XCTAssertEqual(grade.dailyHistory?.stats?.changes?.month, Decimal(string: "-12.5"))
        XCTAssertEqual(response.product.imageURL?.absoluteString, "https://cdn.tcgtracking.com/product/42_400w.jpg")
    }

    func testZeroMissingAndInvalidNumericValuesNeverBecomeGuessedPrices() async throws {
        let rows: [[String: Any]] = [
            ["grader": "PSA", "grade": "10", "guide_value": 0, "market_value": NSNull(), "pop": NSNull(), "sales": 0],
            ["grader": "PSA", "grade": "9", "guide_value": -1, "market_value": true, "pop": -2, "sales": "12", "confidence": 6],
            ["grader": "PSA", "grade": "8", "guide_value": "NaN", "market_value": "1,000", "pop": true]
        ]
        let grades = try details(fixture(grades: rows)).product.variants["EN:Holofoil"]!.grades
        XCTAssertEqual(grades[0].guideValue, 0); XCTAssertNil(grades[0].marketValue); XCTAssertNil(grades[0].population)
        XCTAssertEqual(grades[0].sales, 0); XCTAssertNil(grades[1].guideValue); XCTAssertNil(grades[1].marketValue)
        XCTAssertNil(grades[1].population); XCTAssertEqual(grades[1].sales, 12); XCTAssertNil(grades[1].confidence)
        XCTAssertNil(grades[2].guideValue); XCTAssertNil(grades[2].marketValue); XCTAssertNil(grades[2].population)
    }

    func testDailySeriesRetainsMissingDatesAndUnknownCountsWithoutZeroFilling() async throws {
        let rows: [[String: Any]] = [["grader": "PSA", "grade": "10", "daily_history": ["series": [
            ["2026-10-20", 0, 0], ["2026-10-18", NSNull(), NSNull()], ["2026-02-30", 2, 3], ["not-a-date", 2, 3], ["2026-10-19", 1]
        ]]]]
        let points = try details(fixture(grades: rows)).product.variants["EN:Holofoil"]!.grades[0].dailyHistory!.series
        XCTAssertEqual(points.map(\.day), ["2026-10-18", "2026-10-20"])
        XCTAssertNil(points[0].sales); XCTAssertNil(points[0].average)
        XCTAssertEqual(points[1].sales, 0); XCTAssertEqual(points[1].average, 0)
    }

    func testMismatchedCatalogIdentitiesAndMalformedBodiesAreRejected() async throws {
        for data in [try fixture(productID: 43), try fixture(categoryID: 1), try fixture(groupID: 1), Data("{}".utf8)] {
            XCTAssertThrowsError(try details(data)) { XCTAssertEqual($0 as? ResearchFailure, .invalidResponse) }
        }
        let oversized = Data(repeating: 32, count: NativeResearchHTTPDataLoader.maximumBytes + 1)
        XCTAssertThrowsError(try details(oversized)) { XCTAssertEqual($0 as? ResearchFailure, .responseTooLarge) }
    }

    func testModelSelectsExactVariantAndGradeWithoutChangingSavedPrice() async throws {
        let saved = card(), response = try details()
        let model = ResearchModel(card: saved, provider: ImmediateResearch(response), grader: "PSA", grade: "10")
        model.refresh(); try await waitUntil { !model.loading }
        XCTAssertEqual(model.selectedVariantKey, "EN:Holofoil")
        XCTAssertEqual(model.selectedGrade?.guideValue, Decimal(string: "100.25"))
        XCTAssertEqual(model.card, saved); XCTAssertEqual(saved.marketPrice, 7)
        model.selectGrade(grader: "PSA", grade: "9")
        XCTAssertNil(model.selectedGrade); XCTAssertNotNil(model.selectionMessage)
        model.selectGrade(grader: "PSA", grade: "10 Black Label")
        XCTAssertNil(model.selectedGrade, "A BGS label must never substitute for a PSA grade")
        model.selectGrade(grader: "BGS", grade: "10 Black Label")
        XCTAssertEqual(model.selectedGrade?.guideValue, 200)
        model.selectGrade(grader: "CGC", grade: "10")
        XCTAssertNil(model.selectedGrade, "Special grade labels must remain distinct")
    }

    func testMissingLanguagePrintingAndAmbiguousExactGradesStayUnavailable() async throws {
        let response = try details()
        for saved in [card(printing: "Normal"), card(language: "Japanese"), card(printing: "1st Edition Holofoil")] {
            let model = ResearchModel(card: saved, provider: ImmediateResearch(response))
            model.refresh(); try await waitUntil { !model.loading }
            XCTAssertNil(model.selectedVariant); XCTAssertNil(model.selectedGrade)
            XCTAssertNotNil(model.selectionMessage)
        }
        let duplicates: [[String: Any]] = [["grader": "PSA", "grade": "10", "guide_value": 1], ["grader": "PSA", "grade": "10", "guide_value": 2]]
        let ambiguous = ResearchModel(card: card(), provider: ImmediateResearch(try details(fixture(grades: duplicates))), grader: "PSA", grade: "10")
        ambiguous.refresh(); try await waitUntil { !ambiguous.loading }
        XCTAssertEqual(ambiguous.availableGrades.count, 1)
        XCTAssertNil(ambiguous.selectedGrade, "Duplicate exact grade rows are ambiguous, even though menu choices are unique")
    }

    func testVariantSelectionIsExplicitAndSurvivesRefresh() async throws {
        let extra: [String: Any] = ["JP:Holofoil": ["language": "JP", "finish": "Holofoil", "grades": [["grader": "PSA", "grade": "10", "guide_value": 3]]],
                                    "EN:Normal": ["language": "EN", "finish": "Normal", "grades": []],
                                    "wrong-key": ["language": "EN", "finish": "Other", "grades": []]]
        let model = ResearchModel(card: card(), provider: ImmediateResearch(try details(fixture(extraVariants: extra))), grader: "PSA", grade: "10")
        model.refresh(); try await waitUntil { !model.loading }
        XCTAssertFalse(model.variantKeys.contains("wrong-key"))
        model.selectVariant("JP:Holofoil"); XCTAssertEqual(model.selectedGrade?.guideValue, 3)
        model.refresh(); XCTAssertNil(model.details)
        try await waitUntil { !model.loading }
        XCTAssertEqual(model.selectedVariantKey, "JP:Holofoil"); XCTAssertEqual(model.selectedGrade?.guideValue, 3)
        model.selectVariant("EN:Normal"); XCTAssertNil(model.selectedGrade)
        model.selectVariant("unknown"); XCTAssertNil(model.selectedVariant)
    }

    func testManualSlabWithoutCertifiedGradeRequiresExplicitGradeSelection() async throws {
        let model = ResearchModel(card: card(), provider: ImmediateResearch(try details()), grader: "PSA", grade: "")
        model.refresh(); try await waitUntil { !model.loading }
        XCTAssertNil(model.selectedGrade)
        XCTAssertEqual(model.selectionMessage, "Choose an available research grade.")
        model.selectGrade(grader: "PSA", grade: "10")
        XCTAssertEqual(model.selectedGrade?.guideValue, Decimal(string: "100.25"))
    }

    func testAmbiguousNormalizedVariantRequiresAnExplicitReturnedKey() async throws {
        let extra: [String: Any] = ["EN: holofoil ": ["language": "EN", "finish": " holofoil ", "grades": [["grader": "RAW", "grade": "Raw", "guide_value": 5]]]]
        let model = ResearchModel(card: card(), provider: ImmediateResearch(try details(fixture(extraVariants: extra))))
        model.refresh(); try await waitUntil { !model.loading }
        XCTAssertNil(model.selectedVariant, "Two normalized labels must not pick the first variant")
        model.selectVariant("EN: holofoil ")
        XCTAssertEqual(model.selectedGrade?.guideValue, 5)
    }

    func testNewCardAndCanceledRequestsRejectLateResearchReplies() async throws {
        let provider = ControlledResearch(), model = ResearchModel(card: card(), provider: provider)
        model.refresh(); try await provider.waitForCalls(1)
        model.changeCard(card("p:43")); try await provider.waitForCalls(2)
        let second = try ResearchProductDetails.decode(fixture(productID: 43), expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 43)
        await provider.complete(1, with: second); try await waitUntil { !model.loading }
        let first = try details()
        await provider.complete(0, with: first); await settle()
        XCTAssertEqual(model.details?.product.productID, 43)
        model.refresh(); try await provider.waitForCalls(3)
        model.cancel(); await provider.complete(2, with: second); await settle()
        XCTAssertNil(model.details); XCTAssertFalse(model.loading)
    }

    func testClientUsesOnlyConfiguredServerAndForwardsExplicitRefresh() async throws {
        let loader = ResearchLoader([.init(data: try fixture()), .init(data: try fixture())])
        let client = ResearchClient(baseURL: URL(string: "https://research.example.com")!, token: "device-token",
                                    resolver: ResearchResolver(1430), loader: loader)
        _ = try await client.research(for: card(), forceRefresh: false)
        _ = try await client.research(for: card(), forceRefresh: true)
        let requests = await loader.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, Array(repeating: "https://research.example.com/api/v1/research/3/1430/42", count: 2))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Api-Key")); XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Shipper-Id"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie")); XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cache-Control"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testClientValidatesOriginIdentityAndLocalSetBeforeNetwork() async throws {
        let loader = ResearchLoader([]), resolver = ResearchResolver(1430)
        for raw in ["http://research.example.com", "https://user:pass@research.example.com", "https://research.example.com?token=x", "https://research.example.com/#fragment", "https://research.example.com/prefix"] {
            let client = ResearchClient(baseURL: URL(string: raw)!, resolver: resolver, loader: loader)
            do { _ = try await client.research(for: card(), forceRefresh: false); XCTFail("Invalid base must not request") }
            catch { XCTAssertEqual(error as? ResearchFailure, .notConfigured) }
        }
        let client = ResearchClient(baseURL: URL(string: "https://research.example.com")!, resolver: resolver, loader: loader)
        for saved in [card("mock:42"), card("p:42?x"), card(game: "Other")] {
            do { _ = try await client.research(for: saved, forceRefresh: false); XCTFail("Unsupported identity") }
            catch { XCTAssertEqual(error as? ResearchFailure, .unsupportedCard) }
        }
        let unknownSet = ResearchClient(baseURL: URL(string: "https://research.example.com")!, resolver: ResearchResolver(nil), loader: loader)
        do { _ = try await unknownSet.research(for: card(), forceRefresh: false); XCTFail("Missing group must not be guessed") }
        catch { XCTAssertEqual(error as? ResearchFailure, .catalogUnavailable) }
        let requests = await loader.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testClientKeepsAuthCoverageTransportAndMalformedResponseFailuresDistinct() async throws {
        let rows: [(ResearchLoader.Reply, ResearchFailure)] = [
            (.init(status: 401), .authorizationRequired), (.init(status: 403), .accessDenied),
            (.init(status: 404), .notCovered), (.init(status: 503), .serviceUnavailable(503)),
            (.init(data: Data("{}".utf8)), .invalidResponse),
            (.init(data: try fixture(), url: URL(string: "https://other.example.com/")), .invalidResponse),
            (.init(data: Data(repeating: 32, count: NativeResearchHTTPDataLoader.maximumBytes + 1)), .responseTooLarge)
        ]
        for (reply, expected) in rows {
            let client = ResearchClient(baseURL: URL(string: "https://research.example.com")!, resolver: ResearchResolver(1430), loader: ResearchLoader([reply]))
            do { _ = try await client.research(for: card(), forceRefresh: false); XCTFail("Failure must remain explicit") }
            catch { XCTAssertEqual(error as? ResearchFailure, expected) }
        }
    }

    func testClientCancellationDoesNotBecomeAConnectionFailureOrReturnAReply() async throws {
        let loader = ControlledResearchLoader()
        let client = ResearchClient(baseURL: URL(string: "https://research.example.com")!, resolver: ResearchResolver(1430), loader: loader)
        let selected = card()
        let request = Task { try await client.research(for: selected, forceRefresh: false) }
        try await loader.waitUntilStarted()
        let data = try fixture()
        request.cancel(); await loader.complete(with: data)
        do { _ = try await request.value; XCTFail("A canceled lookup cannot return research") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransportErrorAndInvalidDeviceTokenRemainExplicit() async throws {
        let failing = ResearchClient(baseURL: URL(string: "https://research.example.com")!, resolver: ResearchResolver(1430), loader: FailingResearchLoader())
        do { _ = try await failing.research(for: card(), forceRefresh: false); XCTFail("Connection failure must remain unavailable") }
        catch { XCTAssertEqual(error as? ResearchFailure, .networkUnavailable) }
        let token = ResearchClient(baseURL: URL(string: "https://research.example.com")!, token: "invalid\nheader",
                                   resolver: ResearchResolver(1430), loader: ResearchLoader([]))
        do { _ = try await token.research(for: card(), forceRefresh: false); XCTFail("Control characters cannot enter request headers") }
        catch { XCTAssertEqual(error as? ResearchFailure, .notConfigured) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Research state did not settle")
        throw URLError(.timedOut)
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() } }
}

private struct ImmediateResearch: ResearchProviding {
    let value: ResearchProductDetails
    init(_ value: ResearchProductDetails) { self.value = value }
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails { value }
}
private actor ControlledResearch: ResearchProviding {
    private var continuations: [CheckedContinuation<ResearchProductDetails, Error>?] = []
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<200 {
            if continuations.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func complete(_ index: Int, with result: ResearchProductDetails) {
        let continuation = continuations[index]; continuations[index] = nil; continuation?.resume(returning: result)
    }
}
private struct ResearchResolver: OpenAPISetResolving {
    let group: Int?
    init(_ group: Int?) { self.group = group }
    func setID(for card: CardCandidate) async throws -> Int? { group }
}
private actor ResearchLoader: ResearchHTTPDataLoading {
    struct Reply: Sendable { var status = 200; var data = Data(); var url: URL? = nil }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}
private struct FailingResearchLoader: ResearchHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
private actor ControlledResearchLoader: ResearchHTTPDataLoading {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var url: URL?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
