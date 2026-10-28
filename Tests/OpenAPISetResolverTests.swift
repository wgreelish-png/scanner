import XCTest
@testable import CardShowScanner

@MainActor final class OpenAPISetResolverTests: XCTestCase {
    private func cache() -> (ScannerDatabaseCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ScannerDatabaseCache(directory: directory), directory)
    }
    private func tagged(_ value: Any) throws -> Data {
        var data = Data([0])
        data.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        return data
    }
    private func card(_ ref: String = "p:42", game: String = "Pokémon", set: String = "Triumphant") -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: game, productID: ref, printing: "Normal"),
            name: "Darkrai", set: set, number: "99/102", marketPrice: nil, imageURL: nil, confidence: 0, printings: ["Normal"])
    }
    private func row(_ ref: String) -> [Any] { [ref, "Darkrai", "99/102", "TM", "Triumphant"] }
    private func install(_ shards: [(group: Int, name: String, refs: [String])], in cache: ScannerDatabaseCache,
                         game: String = "tcgp:3", version: String = "first") async throws {
        let path = game.replacingOccurrences(of: ":", with: "-") + "/" + version + ".json"
        let directory = String(path.prefix(through: path.lastIndex(of: "/")!))
        var records: [[String: Any]] = []
        for (offset, shard) in shards.enumerated() {
            let file = version + "-\(offset).meta"
            records.append(["group_id": shard.group, "name": shard.name, "abbr": "S\(offset)", "meta": file])
            try await cache.write("m:" + directory + file, data: tagged(["refs": shard.refs.map(row), "k": 1]))
        }
        try await cache.write("M:" + path, data: tagged(["v": 2, "shards": records]))
        try await cache.write("cur:" + game, data: tagged(path))
    }

    func testExactReferenceWinsOverSetNameAndCollectorNumber() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([(10, "Triumphant", ["p:7"]), (20, "Different Display Name", ["p:42"])], in: cache)
        let resolver = NativeOpenAPISetResolver(cache: cache)
        let actual = try await resolver.setID(for: card())
        XCTAssertEqual(actual, 20)
        let missing = try await resolver.setID(for: card("p:99"))
        XCTAssertNil(missing, "A matching display set/name/number cannot supply a product's group")
        let renamed = try await resolver.setID(for: card(set: "Unrelated historical spelling"))
        XCTAssertEqual(renamed, 20)
    }

    func testAllThreeGamesAreIsolatedAndOnlyProductReferencesAreAccepted() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        for (name, key, group) in [("Pokémon", "tcgp:3", 30), ("Magic: The Gathering", "tcgp:1", 10), ("Yu-Gi-Oh!", "tcgp:2", 20)] {
            try await install([(group, "Triumphant", ["p:42", "t:42", "ts:42", "u:42"])], in: cache, game: key)
            let actual = try await resolver.setID(for: card(game: name))
            XCTAssertEqual(actual, group)
        }
        for ref in ["42", "t:42", "ts:42", "u:42", "P:42", "p:0042", "p:42suffix", "p:0", "p:1234567890123"] {
            let actual = try await resolver.setID(for: card(ref))
            XCTAssertNil(actual, ref)
        }
        let unsupported = try await resolver.setID(for: card(game: "Other"))
        XCTAssertNil(unsupported)
    }

    func testConflictingGroupsFailClosedEvenWhenOneSetNameMatches() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([(10, "Triumphant", ["p:42"]), (20, "Other", ["p:42"]), (10, "Another", ["p:42"])], in: cache)
        let ambiguous = try await NativeOpenAPISetResolver(cache: cache).setID(for: card())
        XCTAssertNil(ambiguous)
        try await install([(10, "Triumphant", ["p:42", "p:42"]), (10, "Other", ["p:42"])], in: cache, version: "same-group")
        let sameGroup = try await NativeOpenAPISetResolver(cache: cache).setID(for: card())
        XCTAssertEqual(sameGroup, 10)
    }

    func testNewManifestAndClearInvalidateResidentMapping() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        try await install([(10, "Triumphant", ["p:42"])], in: cache)
        let first = try await resolver.setID(for: card())
        XCTAssertEqual(first, 10)
        try await install([(20, "Triumphant", ["p:42"])], in: cache, version: "second")
        let next = try await resolver.setID(for: card())
        XCTAssertEqual(next, 20)
        try await install([(30, "Triumphant", ["p:42"])], in: cache, version: "second")
        let overwritten = try await resolver.setID(for: card())
        XCTAssertEqual(overwritten, 30, "A replacement manifest at the same path also invalidates the index")
        try await cache.clear()
        let cleared = try await resolver.setID(for: card())
        XCTAssertNil(cleared)
    }

    func testMissingCorruptAndLegacyDataAreUnavailableWithoutStartingScanner() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        let empty = try await resolver.setID(for: card())
        XCTAssertNil(empty)
        try await cache.write("index", data: tagged(["games": ["tcgp:3": ["ver": "legacy"]]]))
        try await cache.write("tcgp:3@legacy", data: Data([2, 0, 0, 0, 2, 91, 93]))
        let legacy = try await resolver.setID(for: card())
        XCTAssertNil(legacy)
        try await install([(10, "Triumphant", ["p:42"])], in: cache)
        try await cache.remove("m:tcgp-3/first-0.meta")
        let missing = try await resolver.setID(for: card())
        XCTAssertNil(missing)
        try await cache.write("m:tcgp-3/first-0.meta", data: Data([0, 123]))
        let corrupt = try await resolver.setID(for: card())
        XCTAssertNil(corrupt)
        let keys = try await cache.keys()
        XCTAssertEqual(keys.count, 5, "Resolution only reads the local fixture; it never downloads a pack")
    }

    func testBooleanNonpositiveAndFractionalGroupIDsAreRejected() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        let invalidGroups: [Any] = [true, 0, -3, 1.5, "123"]
        for group in invalidGroups {
            try await cache.write("cur:tcgp:3", data: tagged("pokemon/manifest.json"))
            try await cache.write("M:pokemon/manifest.json", data: tagged(["v": 2, "shards": [["group_id": group, "meta": "metadata"]]]))
            try await cache.write("m:pokemon/metadata", data: tagged(["refs": [row("p:42")]]))
            let actual = try await resolver.setID(for: card())
            XCTAssertNil(actual)
        }
    }

    func testIncompleteOtherShardCannotHideAConflictingMapping() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        try await install([(10, "Triumphant", ["p:42"]), (20, "Other", ["p:99"])], in: cache)
        try await cache.remove("m:tcgp-3/first-1.meta")
        let actual = try await NativeOpenAPISetResolver(cache: cache).setID(for: card())
        XCTAssertNil(actual, "Finding the ref in the preferred set cannot skip an unreadable shard")
    }

    func testUnboundedShardListIsRejectedBeforeMetadataReads() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let shards = Array(repeating: ["group_id": 10, "meta": "metadata"] as [String: Any],
                           count: ScannerDatabaseCache.maximumKeys / 2 + 1)
        try await cache.write("cur:tcgp:3", data: tagged("pokemon/manifest.json"))
        try await cache.write("M:pokemon/manifest.json", data: tagged(["v": 2, "shards": shards]))
        let actual = try await NativeOpenAPISetResolver(cache: cache).setID(for: card())
        XCTAssertNil(actual)
    }

    func testUnsafeManifestPathsAndMetadataPathsAreRejected() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        for path in ["../manifest.json", "/absolute.json", "pokemon//manifest.json", "https://example.com/manifest.json"] {
            try await cache.write("cur:tcgp:3", data: tagged(path))
            let actual = try await resolver.setID(for: card())
            XCTAssertNil(actual)
        }
        try await cache.write("cur:tcgp:3", data: tagged("pokemon/manifest.json"))
        try await cache.write("M:pokemon/manifest.json", data: tagged(["v": 2, "shards": [["group_id": 1, "meta": "../metadata"]]]))
        let actual = try await resolver.setID(for: card())
        XCTAssertNil(actual)
    }

    func testCancellationIsPropagatedInsteadOfReportedAsMissingCatalog() async throws {
        let (cache, directory) = cache(); defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = NativeOpenAPISetResolver(cache: cache)
        let selected = card()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.setID(for: selected)
        }
        do { _ = try await task.value; XCTFail("Cancellation must reach the pricing caller") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
