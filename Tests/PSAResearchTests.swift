import XCTest
@testable import CardShowScanner

@MainActor final class PSAResearchTests: XCTestCase {
    private func body(_ certificate: String = "00123456", grade: String = "9", qualifiers: [String] = [], autograph: String? = nil) throws -> Data {
        var value: [String: Any] = ["certificateNumber": certificate, "grader": "PSA", "grade": grade,
                                  "name": "Darkrai & Cresselia LEGEND", "set": "Triumphant", "number": "99/102",
                                  "source": "Authorized fixture adapter", "qualifiers": qualifiers]
        if let autograph { value["autographGrade"] = autograph }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testCertificateIdentityLeadingZerosAndFullGradeArePreserved() async throws {
        let details = try PSACertificateMetadata.decode(body(grade: "9 (OC)", qualifiers: ["OC"], autograph: "10"), certificateNumber: "00123456")
        XCTAssertEqual(details.certificateNumber, "00123456")
        XCTAssertEqual(details.grade, "9 (OC)")
        XCTAssertEqual(details.researchGrade, "9 (OC)")
        XCTAssertEqual(details.autographGrade, "10")
        XCTAssertEqual(details.suggestedSearch, "Darkrai & Cresselia LEGEND 99/102")
    }
    func testSeparateQualifiersNeverCollapseIntoUnqualifiedResearchGrade() async throws {
        let details = try PSACertificateMetadata.decode(body(grade: "9", qualifiers: ["OC", "ST"]), certificateNumber: "00123456")
        XCTAssertEqual(details.researchGrade, "9 (OC, ST)")
        XCTAssertNotEqual(details.researchGrade, "9")
        let authentic = try PSACertificateMetadata.decode(body(grade: "Authentic"), certificateNumber: "00123456")
        XCTAssertEqual(authentic.researchGrade, "Authentic")
    }
    func testWrongCertificateGraderAndMalformedMetadataAreRejected() async throws {
        XCTAssertThrowsError(try PSACertificateMetadata.decode(body("12345678"), certificateNumber: "00123456"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body()) as? [String: Any])
        for change in [["grader": "BGS"], ["name": ""], ["grade": ""], ["source": ""], ["imageURL": "http://example.com/card.jpg"]] {
            var modified = object
            for (key, value) in change { modified[key] = value }
            XCTAssertThrowsError(try PSACertificateMetadata.decode(JSONSerialization.data(withJSONObject: modified), certificateNumber: "00123456"))
        }
        object["certificateNumber"] = 123456
        XCTAssertThrowsError(try PSACertificateMetadata.decode(JSONSerialization.data(withJSONObject: object), certificateNumber: "00123456"))
    }
    func testClientUsesOnlyConfiguredServerAndExactCertificate() async throws {
        let loader = PSATestHTTP(data: try body())
        let client = PSACertificateClient(baseURL: URL(string: "https://research.example.com")!, deviceToken: "device-only-token", loader: loader)
        let result = try await client.lookup("00123456")
        XCTAssertEqual(result.certificateNumber, "00123456")
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://research.example.com/api/v1/psa/cert/00123456")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer device-only-token")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Shipper-Id"))
    }
    func testUnconfiguredCertificateAdapterDoesNotPretendToReturnMetadata() async throws {
        let loader = PSATestHTTP(data: Data(), status: 501)
        let client = PSACertificateClient(baseURL: URL(string: "https://research.example.com")!, deviceToken: "device-token", loader: loader)
        do { _ = try await client.lookup("00123456"); XCTFail("Unconfigured lookup must be explicit") }
        catch { XCTAssertEqual(error as? PSACertificateFailure, .notConfigured) }
    }
    func testClientRejectsInvalidCertificatesConfigurationAndRedirectedResponses() async throws {
        let loader = PSATestHTTP(data: try body())
        let client = PSACertificateClient(baseURL: URL(string: "https://research.example.com")!, deviceToken: "token", loader: loader)
        for value in ["", "https://evil.example/cert/00123456", "00123456?x", " 00123456 ", "abc12345"] {
            do { _ = try await client.lookup(value); XCTFail("Invalid identifier") }
            catch { XCTAssertEqual(error as? PSACertificateFailure, .invalidCertificate) }
        }
        let calls = await loader.requests.count; XCTAssertEqual(calls, 0)
        for value in ["http://research.example.com", "https://user:password@research.example.com", "https://research.example.com?token=x"] {
            let invalid = PSACertificateClient(baseURL: URL(string: value)!, deviceToken: "token", loader: loader)
            do { _ = try await invalid.lookup("00123456"); XCTFail("Invalid configuration") }
            catch { XCTAssertEqual(error as? ResearchFailure, .notConfigured) }
        }
        let redirected = PSACertificateClient(baseURL: URL(string: "https://research.example.com")!, deviceToken: "token",
                                              loader: PSATestHTTP(data: try body(), responseURL: URL(string: "https://another.example.com")))
        do { _ = try await redirected.lookup("00123456"); XCTFail("A reply from another origin is invalid") }
        catch { XCTAssertEqual(error as? PSACertificateFailure, .invalidResponse) }
    }
    func testChangingCertificateDiscardsOldMetadataAndLateResponse() async throws {
        let lookup = PendingPSATestLookup(), model = PSAResearchModel(lookup: lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00123456", kind: .manual)))
        try await waitForCalls(1, lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00987654", kind: .manual)))
        XCTAssertNil(model.metadata); XCTAssertTrue(model.loading)
        try await waitForCalls(2, lookup)
        let latest = try PSACertificateMetadata.decode(body("00987654", grade: "10"), certificateNumber: "00987654")
        await lookup.complete(1, value: latest)
        try await waitUntil { !model.loading }
        let stale = try PSACertificateMetadata.decode(body(), certificateNumber: "00123456")
        await lookup.complete(0, value: stale)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.certificateNumber, "00987654")
        XCTAssertEqual(model.metadata, latest)
    }
    func testLeavingFlowPreventsLateLookupPublication() async throws {
        let lookup = PendingPSATestLookup(), model = PSAResearchModel(lookup: lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00123456", kind: .manual)))
        try await waitForCalls(1, lookup); model.cancel()
        await lookup.complete(0, value: try PSACertificateMetadata.decode(body(), certificateNumber: "00123456"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.loading); XCTAssertNil(model.metadata)
        XCTAssertEqual(model.certificateNumber, "00123456")
        XCTAssertNil(model.message)
    }
    func testRetryAfterLeavingFlowKeepsCertificateAndAcceptsOnlyNewReply() async throws {
        let lookup = PendingPSATestLookup(), model = PSAResearchModel(lookup: lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00123456", kind: .manual)))
        try await waitForCalls(1, lookup); model.cancel(); model.retry()
        try await waitForCalls(2, lookup)
        let latest = try PSACertificateMetadata.decode(body(grade: "10"), certificateNumber: "00123456")
        await lookup.complete(1, value: latest)
        try await waitUntil { !model.loading }
        await lookup.complete(0, value: try PSACertificateMetadata.decode(body(grade: "9"), certificateNumber: "00123456"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.certificateNumber, "00123456"); XCTAssertEqual(model.metadata, latest)
    }
    func testEditingCertificateClearsFrozenMetadataAndRetiresLookup() async throws {
        let lookup = PendingPSATestLookup(), model = PSAResearchModel(lookup: lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00123456", kind: .manual)))
        try await waitForCalls(1, lookup)
        await lookup.complete(0, value: try PSACertificateMetadata.decode(body(), certificateNumber: "00123456"))
        try await waitUntil { !model.loading }
        XCTAssertNotNil(model.metadata)
        model.clear()
        XCTAssertEqual(model.certificateNumber, ""); XCTAssertNil(model.metadata); XCTAssertNil(model.message)
    }
    func testMismatchedLookupMetadataEndsLoadingWithExplicitFailure() async throws {
        let lookup = PendingPSATestLookup(), model = PSAResearchModel(lookup: lookup)
        model.accept(try XCTUnwrap(PSACertificateCode.parse("00123456", kind: .manual)))
        try await waitForCalls(1, lookup)
        await lookup.complete(0, value: try PSACertificateMetadata.decode(body("00987654"), certificateNumber: "00987654"))
        try await waitUntil { !model.loading }
        XCTAssertNil(model.metadata)
        XCTAssertEqual(model.message, PSACertificateFailure.invalidResponse.errorDescription)
    }
    private func waitForCalls(_ count: Int, _ lookup: PendingPSATestLookup) async throws {
        for _ in 0..<100 {
            let calls = await lookup.count
            if calls >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected certificate lookup did not start")
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Lookup did not finish")
    }
}

private actor PSATestHTTP: ResearchHTTPDataLoading {
    let payload: Data
    let status: Int
    let responseURL: URL?
    private(set) var requests: [URLRequest] = []
    init(data: Data, status: Int = 200, responseURL: URL? = nil) { payload = data; self.status = status; self.responseURL = responseURL }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (payload, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private actor PendingPSATestLookup: PSACertificateLookingUp {
    private var continuations: [CheckedContinuation<PSACertificateMetadata, Error>?] = []
    var count: Int { continuations.count }
    func lookup(_ certificateNumber: String) async throws -> PSACertificateMetadata {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(_ index: Int, value: PSACertificateMetadata) {
        let continuation = continuations[index]; continuations[index] = nil
        continuation?.resume(returning: value)
    }
}
