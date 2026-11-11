import XCTest
@testable import CardShowScanner

@MainActor final class ManualCatalogFilterTests: XCTestCase {
    private func tagged(_ value: Any) throws -> Data {
        var data = Data([0]); data.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])); return data
    }
    private func row(_ id: Int, number: String, set: String, name: String = "Fixture Card", abbreviation: String = "FX") -> [Any] {
        ["p:\(id)", name, number, abbreviation, set, "", "", [["label": "Normal", "primary": true]]]
    }
    private func install(_ rows: [[Any]], cache: ScannerDatabaseCache, version: String = "filters") async throws {
        let path = "tcgp-3/\(version).json"
        try await cache.write("cur:tcgp:3", data: tagged(path))
        try await cache.write("M:" + path, data: tagged(["v": 2, "shards": [["meta": version + "-meta", "n": rows.count]]]))
        try await cache.write("m:tcgp-3/" + version + "-meta", data: tagged(["k": 1, "refs": rows]))
    }
    private func fixture() -> (ScannerDatabaseCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualFilters-" + UUID().uuidString)
        return (ScannerDatabaseCache(directory: directory), directory)
    }

    func testFiltersSearchEntireCatalogBeforeFiveResultLimit() async throws {
        let (cache, directory) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (1...9).map { row($0, number: String($0), set: $0 == 9 ? "Target Expansion" : "Earlier Set") }
        try await install(rows, cache: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let unfiltered = try await catalog.search("fixture", game: "Pokémon", limit: 5)
        XCTAssertEqual(unfiltered.count, 5)
        XCTAssertFalse(unfiltered.contains { $0.identity.productID == "p:9" })
        let filtered = try await catalog.search("fixture", game: "Pokémon", limit: 5,
            filters: .init(set: "target expansion"))
        XCTAssertEqual(filtered.map { $0.identity.productID }, ["p:9"])
        XCTAssertNil(filtered.first?.marketPrice); XCTAssertNil(filtered.first?.identity.skuID)
    }

    func testSetAndNumberFiltersCombineAndDoNotMatchNameInsteadOfSet() async throws {
        let (cache, directory) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([row(1, number: "099/102", set: "Triumphant", abbreviation: "TM"),
                           row(2, number: "199/200", set: "Triumphant"),
                           row(3, number: "99/102", set: "Other", name: "Triumphant Fixture Card")], cache: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let matches = try await catalog.search("fixture", game: "Pokémon", limit: 5,
            filters: .init(set: "tm", number: "99"))
        XCTAssertEqual(matches.map { $0.identity.productID }, ["p:1"])
        XCTAssertEqual(matches.first?.number, "099/102", "Comparison normalization must not modify exported collector numbers")
        let wrongTotal = try await catalog.search("", game: "Pokémon", limit: 5,
            filters: .init(set: "triumphant", number: "99/200"))
        XCTAssertTrue(wrongTotal.isEmpty)
    }

    func testFilterOnlySearchSupportsLongAndAlphanumericCollectorNumbersWithoutIntegerConversion() async throws {
        let (cache, directory) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let longNumber = "0001234567890123456789012345678901234567890"
        try await install([row(1, number: "TG01/TG030", set: "Trainer Gallery"),
                           row(2, number: "TG10/TG030", set: "Trainer Gallery"),
                           row(3, number: longNumber, set: "Long Collector Codes"),
                           row(4, number: "LOB-001", set: "Legend of Blue Eyes")], cache: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let gallery = try await catalog.search("", game: "Pokémon", limit: 5, filters: .init(number: "tg1"))
        XCTAssertEqual(gallery.map { $0.identity.productID }, ["p:1"])
        let full = try await catalog.search("", game: "Pokémon", limit: 5,
            filters: .init(number: "TG001 / TG30"))
        XCTAssertEqual(full.map { $0.identity.productID }, ["p:1"])
        let long = try await catalog.search("", game: "Pokémon", limit: 5,
            filters: .init(number: String(longNumber.dropFirst(3))))
        XCTAssertEqual(long.map { $0.identity.productID }, ["p:3"])
        XCTAssertEqual(long.first?.number, longNumber)
        let code = try await catalog.search("", game: "Pokémon", limit: 5, filters: .init(number: "LOB 1"))
        XCTAssertEqual(code.map { $0.identity.productID }, ["p:4"])
    }

    func testClearingAndChangingFiltersKeepsUnfilteredRankingAndHonorsManifestChanges() async throws {
        let (cache, directory) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([row(1, number: "1/10", set: "First"), row(2, number: "2/10", set: "Second")], cache: cache)
        let catalog = CachedCardCatalog(cache: cache)
        let before = try await catalog.search("fixture", game: "Pokémon", limit: 5)
        let first = try await catalog.search("fixture", game: "Pokémon", limit: 5, filters: .init(set: "first"))
        let second = try await catalog.search("fixture", game: "Pokémon", limit: 5, filters: .init(set: "second"))
        XCTAssertEqual(first.map { $0.identity.productID }, ["p:1"])
        XCTAssertEqual(second.map { $0.identity.productID }, ["p:2"])
        let cleared = try await catalog.search("fixture", game: "Pokémon", limit: 5, filters: .init())
        XCTAssertEqual(cleared, before)
        try await install([row(3, number: "3/10", set: "Third")], cache: cache, version: "newer")
        let changed = try await catalog.search("", game: "Pokémon", limit: 5, filters: .init(set: "third"))
        XCTAssertEqual(changed.map { $0.identity.productID }, ["p:3"])
        let punctuation = try await catalog.search("", game: "Pokémon", limit: 5, filters: .init(number: "/"))
        XCTAssertTrue(punctuation.isEmpty)
    }

    func testCanceledFilteredRequestDoesNotContinueIntoCatalogRead() async throws {
        let (cache, directory) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = CachedCardCatalog(cache: cache)
        let task = Task { try await catalog.search("fixture", game: "Pokémon", limit: 5, filters: .init(set: "first")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not be reported as a missing catalog") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLegacyCatalogConformersReceiveCombinedQueryInsteadOfPostFilteringLimitedResults() async throws {
        let catalog = RecordingLegacyCatalog()
        _ = try await catalog.search("Fixture", game: "Pokémon", limit: 5, filters: .init(set: "Target", number: "99"))
        let query = await catalog.lastQuery
        XCTAssertEqual(query, "Fixture Target 99")
    }
}

private actor RecordingLegacyCatalog: CardCatalogSearching {
    private(set) var lastQuery: String?
    func search(_ query: String, game: String, limit: Int) async throws -> [CardCandidate] {
        lastQuery = query; return []
    }
}
