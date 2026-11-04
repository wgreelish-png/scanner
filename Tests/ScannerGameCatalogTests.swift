import XCTest
@testable import CardShowScanner

@MainActor final class ScannerGameCatalogTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let name = "ScannerGameCatalogTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func v2(_ path: String = "pokemon/current/manifest.json") -> [String: Any] {
        ["n": 10, "v2": ["manifest": path]]
    }

    private func index(_ games: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["games": games])
    }

    private func waitForCalls(_ count: Int, loader: ScannerGameCatalogFixtureLoader,
                              file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            let observed = await loader.count
            if observed >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected catalog request did not start", file: file, line: line)
    }

    func testAvailabilityUsesOnlyKnownCardPacksAndStableCanonicalNames() throws {
        let data = try index(["tcgp:3": v2(), "tcgp:85": v2("pokemon-japan/manifest.json"),
            "tcgp:68": v2("onepiece/manifest.json"), "tcgp:31": v2("sleeves/manifest.json"),
            "tcgp:999": v2("unknown/manifest.json"), "tcgp:003": v2(),
            "tcgp:63": ["n": 10, "ver": "2026-11-04", "bin": "digimon/cards.bin.gz",
                        "meta": "digimon/cards.meta.json.gz", "bin_bytes": 100, "meta_bytes": 100]])
        XCTAssertEqual(try ScannerGameCatalog.availableGames(in: data),
                       ["Pokémon", "Digimon Card Game", "One Piece Card Game", "Pokemon Japan"])
    }

    func testEmptyBadShapesAndUnsafePackPathsCannotPublishAvailability() throws {
        let badRoots: [Any] = [[], [:], ["games": []], ["games": [:]], ["games": ["tcgp:3": true]]]
        for value in badRoots {
            XCTAssertThrowsError(try ScannerGameCatalog.availableGames(in: JSONSerialization.data(withJSONObject: value)))
        }
        for path in ["../pokemon/manifest.json", "/absolute.json", "https://example.com/manifest.json",
                     "a//manifest.json", "a/./manifest.json", "a/../manifest.json", "a\\manifest.json",
                     "a%2Fmanifest.json", "a/manifest.json?token=1", "a/manifest.json#fragment"] {
            XCTAssertThrowsError(try ScannerGameCatalog.availableGames(in: index(["tcgp:3": v2(path)])), path)
        }
        let invalidEntries: [Any] = [
            ["n": 0, "v2": ["manifest": "pokemon/manifest.json"]],
            ["n": true, "v2": ["manifest": "pokemon/manifest.json"]],
            ["v2": NSNull()], ["v2": ["manifest": 42]],
            ["ver": "1", "bin": "pokemon/cards.bin", "meta": "pokemon/cards.json"],
            ["ver": true, "bin": "pokemon/cards.bin", "meta": "pokemon/cards.json", "bin_bytes": 10, "meta_bytes": 10]
        ]
        for value in invalidEntries {
            XCTAssertThrowsError(try ScannerGameCatalog.availableGames(in: index(["tcgp:3": value])))
        }
        XCTAssertThrowsError(try ScannerGameCatalog.availableGames(in: Data(repeating: 32, count: 1_048_577)))
    }

    func testSuccessfulDiscoveryCachesActualAvailabilityWithoutInventingMissingLegacyPacks() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try index(["tcgp:68": v2("onepiece/manifest.json"), "tcgp:71": v2("lorcana/manifest.json")])
        let catalog = ScannerGameCatalog(defaults: defaults, now: { date }, loader: { data })
        XCTAssertEqual(catalog.games.count, 8)
        XCTAssertEqual(catalog.games.first, "Pokémon")
        await catalog.refresh()
        XCTAssertEqual(catalog.games, ["Disney Lorcana", "One Piece Card Game"])
        XCTAssertFalse(catalog.isLoading)
        XCTAssertEqual(defaults.stringArray(forKey: ScannerGameCatalog.cacheKeysPreference), ["tcgp:71", "tcgp:68"])
        XCTAssertEqual(defaults.object(forKey: ScannerGameCatalog.cacheDatePreference) as? Date, date)
        let restored = ScannerGameCatalog(defaults: defaults, now: { date }, loader: { throw ScannerGameCatalogFixtureFailure.offline })
        XCTAssertEqual(restored.games, catalog.games)
    }

    func testSavedAvailabilitySurvivesOfflineAndMalformedRefreshes() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(["tcgp:63", "tcgp:3"], forKey: ScannerGameCatalog.cacheKeysPreference)
        defaults.set(date.addingTimeInterval(-604_800), forKey: ScannerGameCatalog.cacheDatePreference)
        let catalog = ScannerGameCatalog(defaults: defaults, now: { date }, loader: { throw ScannerGameCatalogFixtureFailure.offline })
        let saved = catalog.games
        await catalog.refreshIfNeeded()
        XCTAssertEqual(catalog.games, saved)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertNotNil(catalog.status)
        let badData = try index(["tcgp:3": v2("../unsafe.json")])
        let malformed = ScannerGameCatalog(defaults: defaults, now: { date }, loader: { badData })
        await malformed.refresh()
        XCTAssertEqual(malformed.games, saved)
        XCTAssertEqual(defaults.object(forKey: ScannerGameCatalog.cacheDatePreference) as? Date,
                       date.addingTimeInterval(-604_800), "Failed checks cannot reset the weekly freshness baseline")
    }

    func testWeeklyRefreshSkipsFreshCacheAndManualRefreshStillRuns() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(["tcgp:3"], forKey: ScannerGameCatalog.cacheKeysPreference)
        defaults.set(date, forKey: ScannerGameCatalog.cacheDatePreference)
        let loader = ScannerGameCatalogFixtureLoader()
        let catalog = ScannerGameCatalog(defaults: defaults, now: { date }, loader: { try await loader.load() })
        await catalog.refreshIfNeeded()
        let beforeManual = await loader.count
        XCTAssertEqual(beforeManual, 0)
        let manual = Task { await catalog.refresh() }
        await waitForCalls(1, loader: loader)
        try await loader.complete(1, data: index(["tcgp:63": v2("digimon/manifest.json")]))
        await manual.value
        XCTAssertEqual(catalog.games, ["Digimon Card Game"])
    }

    func testCancelInvalidatesLateResponseWithoutChangingChoicesOrCache() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let loader = ScannerGameCatalogFixtureLoader()
        let catalog = ScannerGameCatalog(defaults: defaults, loader: { try await loader.load() })
        let original = catalog.games
        let refresh = Task { await catalog.refresh() }
        await waitForCalls(1, loader: loader)
        XCTAssertTrue(catalog.isLoading)
        catalog.cancel()
        XCTAssertFalse(catalog.isLoading)
        try await loader.complete(1, data: index(["tcgp:63": v2("digimon/manifest.json")]))
        await refresh.value
        XCTAssertEqual(catalog.games, original)
        XCTAssertNil(defaults.object(forKey: ScannerGameCatalog.cacheKeysPreference))
    }

    func testSupersededRequestCannotOverwriteNewerDiscoveryOrCache() async throws {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        let loader = ScannerGameCatalogFixtureLoader()
        let catalog = ScannerGameCatalog(defaults: defaults, loader: { try await loader.load() })
        let first = Task { await catalog.refresh() }
        await waitForCalls(1, loader: loader)
        let second = Task { await catalog.refresh() }
        await waitForCalls(2, loader: loader)
        try await loader.complete(2, data: index(["tcgp:71": v2("lorcana/manifest.json")]))
        await second.value
        try await loader.complete(1, data: index(["tcgp:3": v2()]))
        await first.value
        XCTAssertEqual(catalog.games, ["Disney Lorcana"])
        XCTAssertEqual(defaults.stringArray(forKey: ScannerGameCatalog.cacheKeysPreference), ["tcgp:71"])
        XCTAssertFalse(catalog.isLoading)
    }

    func testInvalidCachedAccessorySelectionFallsBackToBundledGames() {
        let (defaults, domain) = preferences(); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["tcgp:3", "tcgp:31"], forKey: ScannerGameCatalog.cacheKeysPreference)
        let catalog = ScannerGameCatalog(defaults: defaults, loader: { throw ScannerGameCatalogFixtureFailure.offline })
        XCTAssertEqual(catalog.games.count, 8)
        XCTAssertEqual(catalog.games.first, "Pokémon")
        XCTAssertFalse(catalog.games.contains("Card Sleeves"))
    }
}

private enum ScannerGameCatalogFixtureFailure: Error { case offline }

private actor ScannerGameCatalogFixtureLoader {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    func load() async throws -> Data {
        count += 1
        let id = count
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func complete(_ id: Int, data: Data) { pending.removeValue(forKey: id)?.resume(returning: data) }
}
